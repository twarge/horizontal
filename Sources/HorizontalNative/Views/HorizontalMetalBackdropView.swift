#if canImport(MetalKit)
import Foundation
import MetalKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// MSL source compiles to an `MTLLibrary` per device exactly once and is
/// shared across every pipeline state. The previous code called
/// `device.makeLibrary(source:)` inside each `make*PipelineState` and also
/// inside `isSupported` — eight+ shader compiles per renderer per document
/// open. `registryID` keys the cache by the underlying GPU.
private enum HorizontalMetalLibraryCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var libraries = [UInt64: MTLLibrary]()
    nonisolated(unsafe) private static var failures = Set<UInt64>()

    static func library(for device: MTLDevice) -> MTLLibrary? {
        let key = device.registryID
        lock.lock()
        defer { lock.unlock() }
        if let cached = libraries[key] {
            return cached
        }
        if failures.contains(key) {
            return nil
        }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            libraries[key] = library
            return library
        } catch {
            failures.insert(key)
            NSLog("Horizontal Metal library compile failed: \(error)")
            return nil
        }
    }
}

// Cross-platform: the SwiftUI representable conformance is added per-platform
// (NSViewRepresentable on macOS, UIViewRepresentable on iOS) in extensions below;
// the stored properties, the Metal `Renderer`, and the make/update logic are
// shared. MTKView, MTLDevice, and the shaders are identical on both platforms.
struct HorizontalMetalBackdropView {
    var bounds: HorizontalRect
    var viewport: CanvasViewport
    var viewportDriver: HorizontalCanvasViewportDriver?
    var fitInsets: HorizontalCanvasInsets
    var grid: HorizontalGridSettings?
    var backgroundColor: Color
    var gridColor: Color
    var minimumLineWidth: CGFloat = 0
    var gridLineWidth: CGFloat = 0.5
    /// Multiplier the renderer applies to per-layer composite textures at draw
    /// time. Lets `BoardCanvasView`'s opacity slider drag without invalidating
    /// any cached primitive buckets — the slider is a uniform update.
    var layerOpacity: Double = 1
    var triangles: [HorizontalMetalTrianglePrimitive] = []
    var triangleKey = 0
    var lines: [HorizontalMetalLinePrimitive] = []
    var lineKey = 0
    var handles: [HorizontalMetalHandlePrimitive] = []
    var handleKey = 0
    var anchoredRects: [HorizontalMetalAnchoredRectPrimitive] = []
    var anchoredRectKey = 0
    var screenTriangles: [HorizontalMetalScreenTrianglePrimitive] = []
    var screenTriangleKey = 0
    var screenLines: [HorizontalMetalScreenLinePrimitive] = []
    var screenLineKey = 0
    var bufferPatches = HorizontalMetalBufferPatches.empty
    var bufferPatchKey = 0
    var visibleCompositeGroups: Set<Int>? = nil
    /// Composite groups that must ignore `layerOpacity` — rendered at their own
    /// full opacity even while the layer-opacity slider dims every other group.
    /// Used for the always-readable overlay-label group (TEXT_OVERLAY).
    var layerOpacityExemptCompositeGroups: Set<Int> = []
    var loadProfileID: String? = nil
    var loadProfileLabel = "Metal"
    var marksLoadProfileFirstDraw = true

    static let isSupported: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }
        return HorizontalMetalLibraryCache.library(for: device) != nil
    }()

    func makeCoordinator() -> Renderer {
        Renderer()
    }

    @MainActor
    fileprivate func makeBackdropView(coordinator: Renderer) -> MTKView {
        #if os(iOS)
        let view = ResizeRedrawingMTKView(frame: .zero, device: coordinator.device)
        #else
        let view = MTKView(frame: .zero, device: coordinator.device)
        #endif
        view.delegate = coordinator
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = coordinator.sampleCount
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        #if os(macOS)
        view.layer?.isOpaque = false
        #else
        view.layer.isOpaque = false
        #endif
        return view
    }

    @MainActor
    fileprivate func updateBackdropView(_ view: MTKView, coordinator: Renderer) {
        #if os(macOS)
        let backingScale = Float(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        #else
        let backingScale = Float(view.contentScaleFactor)
        #endif
        let viewportSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)) / max(backingScale, 1)
        if viewportDriver?.isConfigured == false {
            viewportDriver?.configure(viewport: viewport)
        }
        coordinator.loadProfileID = loadProfileID
        coordinator.loadProfileLabel = loadProfileLabel
        coordinator.marksLoadProfileFirstDraw = marksLoadProfileFirstDraw
        let profileStart = BoardLoadTimer.timingStart()
        coordinator.update(
            bounds: bounds,
            // The driver's viewport is the freshest (the SwiftUI `viewport`
            // here is the throttled chrome value, up to a gesture-frame stale);
            // never write a stale pan/zoom into the uniforms, even though the
            // `register` call below re-syncs — that call being load-bearing for
            // correctness is exactly the trap this avoids.
            viewport: viewportDriver?.viewport ?? viewport,
            fitInsets: fitInsets,
            grid: grid,
            backgroundColor: backgroundColor,
            gridColor: gridColor,
            minimumLineWidth: Float(minimumLineWidth),
            gridLineWidth: Float(gridLineWidth),
            layerOpacity: Float(layerOpacity),
            triangles: triangles,
            triangleKey: triangleKey,
            lines: lines,
            lineKey: lineKey,
            handles: handles,
            handleKey: handleKey,
            anchoredRects: anchoredRects,
            anchoredRectKey: anchoredRectKey,
            screenTriangles: screenTriangles,
            screenTriangleKey: screenTriangleKey,
            screenLines: screenLines,
            screenLineKey: screenLineKey,
            bufferPatches: bufferPatches,
            bufferPatchKey: bufferPatchKey,
            visibleCompositeGroups: visibleCompositeGroups,
            layerOpacityExemptCompositeGroups: layerOpacityExemptCompositeGroups,
            backingScale: backingScale,
            viewportSize: viewportSize
        )
        if let loadProfileID {
            BoardLoadTimer.recordBoard2DStep(
                "\(loadProfileLabel) updateNSView",
                nanoseconds: BoardLoadTimer.elapsedNanoseconds(since: profileStart),
                id: loadProfileID
            )
        }
        // Load-bearing: registration re-pushes the driver's live viewport into
        // this renderer's uniforms, keeping every stacked canvas layer on the
        // same pan/zoom even if a stale value slipped in above.
        viewportDriver?.register(renderer: coordinator, view: view)
        #if os(macOS)
        view.needsDisplay = true
        view.setNeedsDisplay(view.bounds)
        #else
        view.setNeedsDisplay()
        #endif
        if !bufferPatches.isEmpty {
            HorizontalMoveRateDiagnostics.mark(.metalForcedDraw)
            view.draw()
        }
    }

    #if os(iOS)
    /// An MTKView (paused, needs-display driven) that requests a draw after
    /// every layout pass. AppKit invalidates a resized NSView on its own, but
    /// UIKit does not — so on iOS a resized canvas kept presenting the old
    /// stretched frame until the next pan or pinch happened to request a draw.
    /// `setNeedsDisplay` here defers the draw to the display phase, keeping the
    /// actual redraw out of the resize's own layout pass (the trade documented
    /// in `drawableSizeWillChange`).
    private final class ResizeRedrawingMTKView: MTKView {
        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsDisplay()
        }
    }
    #endif

    final class Renderer: NSObject, MTKViewDelegate {
        var loadProfileID: String?
        var loadProfileLabel = "Metal"
        var marksLoadProfileFirstDraw = true

        let device: MTLDevice?
        let sampleCount: Int
        private let commandQueue: MTLCommandQueue?
        private var backdropPipelineState: MTLRenderPipelineState?
        private var trianglePipelineState: MTLRenderPipelineState?
        private var linePipelineState: MTLRenderPipelineState?
        private var handlePipelineState: MTLRenderPipelineState?
        private var anchoredRectPipelineState: MTLRenderPipelineState?
        private var screenTrianglePipelineState: MTLRenderPipelineState?
        private var screenLinePipelineState: MTLRenderPipelineState?
        private var offscreenTrianglePipelineState: MTLRenderPipelineState?
        private var offscreenLinePipelineState: MTLRenderPipelineState?
        private var offscreenAnchoredRectPipelineState: MTLRenderPipelineState?
        private var textureCompositePipelineState: MTLRenderPipelineState?
        private var uniforms = HorizontalMetalBackdropUniforms()
        private var triangleBuffer: MTLBuffer?
        private var triangleBufferStorage = HorizontalMetalBufferStorage<HorizontalMetalTriangleShaderPrimitive>()
        private var trianglePrimitiveCount = 0
        private var currentTriangleKey: Int?
        private var lineBuffer: MTLBuffer?
        private var lineBufferStorage = HorizontalMetalBufferStorage<HorizontalMetalLineShaderPrimitive>()
        private var linePrimitiveCount = 0
        private var currentLineKey: Int?
        private var handleBuffer: MTLBuffer?
        private var handleBufferStorage = HorizontalMetalBufferStorage<HorizontalMetalHandleShaderPrimitive>()
        private var handlePrimitiveCount = 0
        private var currentHandleKey: Int?
        private var anchoredRectBuffer: MTLBuffer?
        private var anchoredRectBufferStorage = HorizontalMetalBufferStorage<HorizontalMetalAnchoredRectShaderPrimitive>()
        private var anchoredRectPrimitiveCount = 0
        private var currentAnchoredRectKey: Int?
        private var screenTriangleBuffer: MTLBuffer?
        private var screenTriangleBufferStorage = HorizontalMetalBufferStorage<HorizontalMetalScreenTriangleShaderPrimitive>()
        private var screenTrianglePrimitiveCount = 0
        private var currentScreenTriangleKey: Int?
        private var screenLineBuffer: MTLBuffer?
        private var screenLineBufferStorage = HorizontalMetalBufferStorage<HorizontalMetalScreenLineShaderPrimitive>()
        private var screenLinePrimitiveCount = 0
        private var currentScreenLineKey: Int?
        private var currentBufferPatchKey: Int?
        private var appliedTranslationDeltas = [HorizontalMetalTranslationPatchKey: SIMD2<Float>]()
        private var compositeBatchBuffers = [HorizontalMetalCompositeBatchBuffers]()
        private var compositeBatchStorageByGroup = [Int: HorizontalMetalCompositeBatchBuffers]()
        private var currentCompositeBatchKey: Int?
        private var compositeRenderTextures = [MTLTexture]()
        private var currentCompositeTextureSize = CGSize.zero
        private var currentBounds = HorizontalRect.empty
        private var currentFitInsets = HorizontalCanvasInsets.defaultFit
        private var currentGrid: HorizontalGridSettings?
        private var currentBackgroundColor = Color.clear
        private var currentGridColor = Color.clear
        private var currentMinimumLineWidth: Float = 0
        private var currentGridLineWidth: Float = 0.5
        private var currentViewport = CanvasViewport()
        private var currentBackingScale: Float = 1
        private var currentViewportSize = SIMD2<Float>(1, 1)
        private var currentVisibleCompositeGroups: Set<Int>?
        private var currentLayerOpacity: Float = 1
        private var currentLayerOpacityExemptCompositeGroups: Set<Int> = []
        private var moveProfilerDrawActiveUntilNanoseconds: UInt64 = 0

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.sampleCount = device?.supportsTextureSampleCount(4) == true ? 4 : 1
            self.commandQueue = device?.makeCommandQueue()
            super.init()
            if let device {
                backdropPipelineState = Self.makeBackdropPipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: sampleCount)
                trianglePipelineState = Self.makeTrianglePipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: sampleCount)
                linePipelineState = Self.makeLinePipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: sampleCount)
                handlePipelineState = Self.makeHandlePipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: sampleCount)
                anchoredRectPipelineState = Self.makeAnchoredRectPipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: sampleCount)
                screenTrianglePipelineState = Self.makeScreenTrianglePipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: sampleCount)
                screenLinePipelineState = Self.makeScreenLinePipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: sampleCount)
                offscreenTrianglePipelineState = Self.makeTrianglePipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: 1)
                offscreenLinePipelineState = Self.makeLinePipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: 1)
                offscreenAnchoredRectPipelineState = Self.makeAnchoredRectPipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: 1)
                textureCompositePipelineState = Self.makeTextureCompositePipelineState(device: device, pixelFormat: .bgra8Unorm, sampleCount: sampleCount)
            }
        }

        func update(
            bounds: HorizontalRect,
            viewport: CanvasViewport,
            fitInsets: HorizontalCanvasInsets,
            grid: HorizontalGridSettings?,
            backgroundColor: Color,
            gridColor: Color,
            minimumLineWidth: Float,
            gridLineWidth: Float,
            layerOpacity: Float,
            triangles: [HorizontalMetalTrianglePrimitive],
            triangleKey: Int,
            lines: [HorizontalMetalLinePrimitive],
            lineKey: Int,
            handles: [HorizontalMetalHandlePrimitive],
            handleKey: Int,
            anchoredRects: [HorizontalMetalAnchoredRectPrimitive],
            anchoredRectKey: Int,
            screenTriangles: [HorizontalMetalScreenTrianglePrimitive],
            screenTriangleKey: Int,
            screenLines: [HorizontalMetalScreenLinePrimitive],
            screenLineKey: Int,
            bufferPatches: HorizontalMetalBufferPatches,
            bufferPatchKey: Int,
            visibleCompositeGroups: Set<Int>?,
            layerOpacityExemptCompositeGroups: Set<Int>,
            backingScale: Float,
            viewportSize: SIMD2<Float>
        ) {
            let profilesMovePatch = !bufferPatches.isEmpty
            if profilesMovePatch {
                HorizontalMoveRateDiagnostics.mark(.metalUpdate)
                moveProfilerDrawActiveUntilNanoseconds = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            }

            HorizontalMoveProfiler.measure("metal.update.total", enabled: profilesMovePatch) {
                currentBounds = bounds
                currentFitInsets = fitInsets
                currentGrid = grid
                currentBackgroundColor = backgroundColor
                currentGridColor = gridColor
                currentMinimumLineWidth = minimumLineWidth
                currentGridLineWidth = gridLineWidth
                currentViewport = viewport
                currentBackingScale = backingScale
                currentViewportSize = viewportSize
                currentVisibleCompositeGroups = visibleCompositeGroups
                currentLayerOpacity = max(0, min(1, layerOpacity))
                currentLayerOpacityExemptCompositeGroups = layerOpacityExemptCompositeGroups

                func profileLoadUpdate<T>(_ label: String, _ work: () -> T) -> T {
                    guard loadProfileID != nil,
                          loadProfileLabel == "Metal overlay" else {
                        return work()
                    }
                    let start = BoardLoadTimer.timingStart()
                    let value = work()
                    BoardLoadTimer.recordBoard2DStep(
                        "\(loadProfileLabel) update: \(label)",
                        nanoseconds: BoardLoadTimer.elapsedNanoseconds(since: start),
                        id: loadProfileID
                    )
                    return value
                }

                HorizontalMoveProfiler.measure("metal.update.uniforms", enabled: profilesMovePatch) {
                    profileLoadUpdate("uniforms") {
                        updateUniforms(viewport: viewport)
                    }
                }

                HorizontalMoveProfiler.measure("metal.update.triangles", enabled: profilesMovePatch) {
                    profileLoadUpdate("direct triangles") {
                        updateTriangleBuffer(triangles: triangles, triangleKey: triangleKey)
                    }
                }
                HorizontalMoveProfiler.measure("metal.update.lines", enabled: profilesMovePatch) {
                    profileLoadUpdate("direct lines") {
                        updateLineBuffer(lines: lines, lineKey: lineKey)
                    }
                }
                HorizontalMoveProfiler.measure("metal.update.handles", enabled: profilesMovePatch) {
                    profileLoadUpdate("handles") {
                        updateHandleBuffer(handles: handles, handleKey: handleKey)
                    }
                }
                HorizontalMoveProfiler.measure("metal.update.anchoredRects", enabled: profilesMovePatch) {
                    profileLoadUpdate("direct anchored rects") {
                        updateAnchoredRectBuffer(anchoredRects: anchoredRects, anchoredRectKey: anchoredRectKey)
                    }
                }
                HorizontalMoveProfiler.measure("metal.update.screenTriangles", enabled: profilesMovePatch) {
                    profileLoadUpdate("screen triangles") {
                        updateScreenTriangleBuffer(screenTriangles: screenTriangles, screenTriangleKey: screenTriangleKey)
                    }
                }
                HorizontalMoveProfiler.measure("metal.update.screenLines", enabled: profilesMovePatch) {
                    profileLoadUpdate("screen lines") {
                        updateScreenLineBuffer(screenLines: screenLines, screenLineKey: screenLineKey)
                    }
                }
                HorizontalMoveProfiler.measure("metal.update.compositeBatches", enabled: profilesMovePatch) {
                    profileLoadUpdate("composite batches") {
                        updateCompositeBatchBuffers(
                            triangles: triangles,
                            lines: lines,
                            anchoredRects: anchoredRects,
                            key: ((triangleKey &* 31) &+ lineKey) &* 31 &+ anchoredRectKey
                        )
                    }
                }
                HorizontalMoveProfiler.measure("metal.update.bufferPatches", enabled: profilesMovePatch) {
                    profileLoadUpdate("buffer patches") {
                        applyBufferPatches(bufferPatches, key: bufferPatchKey)
                    }
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            currentViewportSize = SIMD2(Float(size.width), Float(size.height)) / max(uniforms.backingScale, 1)
            updateUniforms(viewport: currentViewport)
            // Deliberately no synchronous `view.draw()` here. Redrawing on every
            // resize step re-fitted the content instead of stretching it, but it
            // put a full canvas redraw inside the resize's own layout pass — for
            // each visible canvas. The content now stretches during the drag and
            // re-fits when it ends, which is the trade named above.
        }

        func updateLiveViewport(_ viewport: CanvasViewport) {
            currentViewport = viewport
            updateUniforms(viewport: viewport)
        }

        func draw(in view: MTKView) {
            let drawTickStart = BoardLoadTimer.tickDrawStart()
            defer { BoardLoadTimer.tickDrawEnd(drawTickStart) }
            let profilesMovePatchDraw = DispatchTime.now().uptimeNanoseconds < moveProfilerDrawActiveUntilNanoseconds
            HorizontalMoveRateDiagnostics.mark(.metalDraw, active: profilesMovePatchDraw)
            let drawableSize = view.drawableSize
            uniforms.viewportSize = SIMD2(Float(drawableSize.width), Float(drawableSize.height)) / max(uniforms.backingScale, 1)

            // Always present asynchronously, including during a live window
            // resize.
            //
            // Resizing used to present in sync with the Core Animation
            // transaction so the freshly-fitted frame swapped in atomically with
            // the layer — no squish, but every resize step then blocked the main
            // thread waiting for the GPU, once per visible canvas. That cost was
            // judged not worth the squish it bought: a stretched frame during the
            // drag is a moment's cosmetic artefact, a janky resize is not.
            //
            // Restoring it is a two-line change — set this from `view.inLiveResize`
            // on macOS and put the synchronous redraw back in
            // `drawableSizeWillChange`. Both halves are needed; either alone gives
            // the cost without the benefit.
            let presentsInTransaction = false
            view.presentsWithTransaction = presentsInTransaction

            // Every early return below re-arms the draw. The view is paused and
            // needs-display driven, so a skipped draw otherwise keeps PRESENTING
            // the previous frame indefinitely — with several stacked canvas
            // layers contending for drawables during a pan, one layer (e.g. the
            // highlight overlay) could stay at a stale pan offset from the
            // others until an unrelated event happened to dirty it.
            func rearmSkippedDraw() {
                #if os(macOS)
                view.setNeedsDisplay(view.bounds)
                #else
                view.setNeedsDisplay()
                #endif
            }
            guard let drawable = view.currentDrawable else {
                recordLoadProfileDrawSkip("no drawable", since: drawTickStart)
                rearmSkippedDraw()
                return
            }
            guard let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let backdropPipelineState else {
                recordLoadProfileDrawSkip("missing pipeline", since: drawTickStart)
                rearmSkippedDraw()
                return
            }

            let activeBatches = activeCompositeBatches()
            // Fast path: when every active layer group is fully opaque (the
            // default — opacity slider at 100%), skip the per-group offscreen
            // textures and draw the grouped primitives inline. Avoids allocating
            // one drawable-sized texture per layer group (gigabytes of VRAM at
            // 5K retina across many layers) plus an extra render pass each.
            // Identical output for opacity 1 (src-over associativity); any
            // translucent group falls back to the offscreen composite path.
            // NOTE: the overlay-label group (textOverlayMetalCompositeGroup) is now
            // opaque (opacity 1.0), so it no longer forces the offscreen path on its
            // own: at layerOpacity 1 its opaque strokes draw inline here (still
            // seam-free — opaque-over-opaque never compounds alpha). When the slider
            // dims copper (layerOpacity < 1) the offscreen path runs and the label
            // group is held at full opacity via layerOpacityExemptCompositeGroups.
            let inlineCompositeGroups = currentLayerOpacity >= 1 && activeBatches.allSatisfy { $0.opacity >= 1 }
            let compositeTextures = HorizontalMoveProfiler.measure("metal.draw.compositeTextures", enabled: profilesMovePatchDraw) {
                inlineCompositeGroups
                    ? []
                    : renderCompositeTextures(commandBuffer: commandBuffer, drawableSize: drawableSize)
            }

            guard let descriptor = view.currentRenderPassDescriptor,
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                recordLoadProfileDrawSkip("missing render pass", since: drawTickStart)
                rearmSkippedDraw()
                return
            }
            if marksLoadProfileFirstDraw {
                BoardLoadTimer.markFirstMetalDraw(loadProfileID)
            }

            HorizontalMoveProfiler.measure("metal.draw.encode", enabled: profilesMovePatchDraw) {
                encoder.setRenderPipelineState(backdropPipelineState)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                if inlineCompositeGroups {
                    encodeInlineCompositeGroups(activeBatches, encoder: encoder)
                } else if let textureCompositePipelineState {
                    for compositeTexture in compositeTextures {
                        // Multiply the per-batch opacity (set when buckets were
                        // built — currently always 1.0 for layered groups) by the
                        // live layerOpacity uniform. Lets the slider drag without
                        // any cache invalidation upstream. Exempt groups (the
                        // overlay-label group) composite at their own opacity so the
                        // labels stay fully readable while copper dims.
                        var opacity = compositeTexture.ignoresLayerOpacity
                            ? compositeTexture.opacity
                            : compositeTexture.opacity * currentLayerOpacity
                        encoder.setRenderPipelineState(textureCompositePipelineState)
                        encoder.setFragmentTexture(compositeTexture.texture, index: 0)
                        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                }

                if let trianglePipelineState, let triangleBuffer, trianglePrimitiveCount > 0 {
                    encoder.setRenderPipelineState(trianglePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(triangleBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: trianglePrimitiveCount * 3)
                }

                if let linePipelineState, let lineBuffer, linePrimitiveCount > 0 {
                    encoder.setRenderPipelineState(linePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(lineBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: linePrimitiveCount * 6)
                }

                if let handlePipelineState, let handleBuffer, handlePrimitiveCount > 0 {
                    encoder.setRenderPipelineState(handlePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(handleBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: handlePrimitiveCount * 6)
                }

                if let anchoredRectPipelineState, let anchoredRectBuffer, anchoredRectPrimitiveCount > 0 {
                    encoder.setRenderPipelineState(anchoredRectPipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(anchoredRectBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: anchoredRectPrimitiveCount * 6)
                }

                if let screenTrianglePipelineState, let screenTriangleBuffer, screenTrianglePrimitiveCount > 0 {
                    encoder.setRenderPipelineState(screenTrianglePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(screenTriangleBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: screenTrianglePrimitiveCount * 3)
                }

                if let screenLinePipelineState, let screenLineBuffer, screenLinePrimitiveCount > 0 {
                    encoder.setRenderPipelineState(screenLinePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(screenLineBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: screenLinePrimitiveCount * 6)
                }

                encoder.endEncoding()
            }
            HorizontalMoveProfiler.measure("metal.draw.commit", enabled: profilesMovePatchDraw) {
                if presentsInTransaction {
                    // presentsWithTransaction requires presenting on the main
                    // thread after the command buffer is scheduled, rather than
                    // asking the command buffer to present asynchronously.
                    commandBuffer.commit()
                    commandBuffer.waitUntilScheduled()
                    drawable.present()
                } else {
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                }
            }
        }

        private func recordLoadProfileDrawSkip(_ reason: String, since start: DispatchTime) {
            guard marksLoadProfileFirstDraw, let loadProfileID else {
                return
            }
            BoardLoadTimer.recordBoard2DStep(
                "\(loadProfileLabel) draw skipped: \(reason)",
                nanoseconds: BoardLoadTimer.elapsedNanoseconds(since: start.uptimeNanoseconds),
                id: loadProfileID
            )
        }

        private func updateTriangleBuffer(triangles: [HorizontalMetalTrianglePrimitive], triangleKey: Int) {
            guard currentTriangleKey != triangleKey else {
                return
            }

            resetIncrementalBufferPatchState()
            currentTriangleKey = triangleKey
            var shaderPrimitives = [HorizontalMetalTriangleShaderPrimitive]()
            shaderPrimitives.reserveCapacity(triangles.count)
            for triangle in triangles where triangle.compositeGroup == 0 {
                shaderPrimitives.append(Self.shaderPrimitive(triangle))
            }
            trianglePrimitiveCount = shaderPrimitives.count
            guard let device, !shaderPrimitives.isEmpty else {
                triangleBuffer = nil
                return
            }

            triangleBuffer = triangleBufferStorage.replace(device: device, primitives: shaderPrimitives)
        }

        private func updateLineBuffer(lines: [HorizontalMetalLinePrimitive], lineKey: Int) {
            guard currentLineKey != lineKey else {
                return
            }

            resetIncrementalBufferPatchState()
            currentLineKey = lineKey
            var shaderPrimitives = [HorizontalMetalLineShaderPrimitive]()
            shaderPrimitives.reserveCapacity(lines.count)
            for line in lines where line.compositeGroup == 0 {
                shaderPrimitives.append(Self.shaderPrimitive(line))
            }
            linePrimitiveCount = shaderPrimitives.count
            guard let device, !shaderPrimitives.isEmpty else {
                lineBuffer = nil
                return
            }

            lineBuffer = lineBufferStorage.replace(device: device, primitives: shaderPrimitives)
        }

        private func updateHandleBuffer(handles: [HorizontalMetalHandlePrimitive], handleKey: Int) {
            guard currentHandleKey != handleKey else {
                return
            }

            resetIncrementalBufferPatchState()
            currentHandleKey = handleKey
            handlePrimitiveCount = handles.count
            guard let device, !handles.isEmpty else {
                handleBuffer = nil
                return
            }

            let shaderPrimitives = handles.map { handle in
                Self.shaderPrimitive(handle)
            }
            handleBuffer = handleBufferStorage.replace(device: device, primitives: shaderPrimitives)
        }

        private func updateAnchoredRectBuffer(
            anchoredRects: [HorizontalMetalAnchoredRectPrimitive],
            anchoredRectKey: Int
        ) {
            guard currentAnchoredRectKey != anchoredRectKey else {
                return
            }

            resetIncrementalBufferPatchState()
            currentAnchoredRectKey = anchoredRectKey
            var shaderPrimitives = [HorizontalMetalAnchoredRectShaderPrimitive]()
            shaderPrimitives.reserveCapacity(anchoredRects.count)
            for rect in anchoredRects where rect.compositeGroup == 0 {
                shaderPrimitives.append(Self.shaderPrimitive(rect))
            }
            anchoredRectPrimitiveCount = shaderPrimitives.count
            guard let device, !shaderPrimitives.isEmpty else {
                anchoredRectBuffer = nil
                return
            }

            anchoredRectBuffer = anchoredRectBufferStorage.replace(device: device, primitives: shaderPrimitives)
        }

        private func updateScreenTriangleBuffer(
            screenTriangles: [HorizontalMetalScreenTrianglePrimitive],
            screenTriangleKey: Int
        ) {
            guard currentScreenTriangleKey != screenTriangleKey else {
                return
            }

            currentScreenTriangleKey = screenTriangleKey
            screenTrianglePrimitiveCount = screenTriangles.count
            guard let device, !screenTriangles.isEmpty else {
                screenTriangleBuffer = nil
                return
            }

            let shaderPrimitives = screenTriangles.map { triangle in
                HorizontalMetalScreenTriangleShaderPrimitive(
                    a: SIMD2(triangle.ax, triangle.ay),
                    b: SIMD2(triangle.bx, triangle.by),
                    c: SIMD2(triangle.cx, triangle.cy),
                    color: triangle.color.simd
                )
            }
            screenTriangleBuffer = screenTriangleBufferStorage.replace(device: device, primitives: shaderPrimitives)
        }

        private func updateScreenLineBuffer(screenLines: [HorizontalMetalScreenLinePrimitive], screenLineKey: Int) {
            guard currentScreenLineKey != screenLineKey else {
                return
            }

            currentScreenLineKey = screenLineKey
            screenLinePrimitiveCount = screenLines.count
            guard let device, !screenLines.isEmpty else {
                screenLineBuffer = nil
                return
            }

            let shaderPrimitives = screenLines.map { line in
                HorizontalMetalScreenLineShaderPrimitive(
                    from: SIMD2(line.fromX, line.fromY),
                    to: SIMD2(line.toX, line.toY),
                    color: line.color.simd,
                    width: line.width,
                    dashLength: line.dashLength,
                    dashGap: line.dashGap,
                    padding: 0
                )
            }
            screenLineBuffer = screenLineBufferStorage.replace(device: device, primitives: shaderPrimitives)
        }

        private func updateCompositeBatchBuffers(
            triangles: [HorizontalMetalTrianglePrimitive],
            lines: [HorizontalMetalLinePrimitive],
            anchoredRects: [HorizontalMetalAnchoredRectPrimitive],
            key: Int
        ) {
            guard currentCompositeBatchKey != key else {
                return
            }

            resetIncrementalBufferPatchState()
            currentCompositeBatchKey = key
            guard let device else {
                compositeBatchBuffers = []
                return
            }

            var trianglesByGroup = [Int: [HorizontalMetalTriangleShaderPrimitive]]()
            var linesByGroup = [Int: [HorizontalMetalLineShaderPrimitive]]()
            var rectsByGroup = [Int: [HorizontalMetalAnchoredRectShaderPrimitive]]()
            var opacityByGroup = [Int: Float]()
            trianglesByGroup.reserveCapacity(32)
            linesByGroup.reserveCapacity(32)
            rectsByGroup.reserveCapacity(32)

            for triangle in triangles where triangle.compositeGroup != 0 {
                trianglesByGroup[triangle.compositeGroup, default: []].append(Self.shaderPrimitive(triangle))
                opacityByGroup[triangle.compositeGroup] = triangle.compositeOpacity
            }
            for line in lines where line.compositeGroup != 0 {
                linesByGroup[line.compositeGroup, default: []].append(Self.shaderPrimitive(line))
                opacityByGroup[line.compositeGroup] = line.compositeOpacity
            }
            for rect in anchoredRects where rect.compositeGroup != 0 {
                rectsByGroup[rect.compositeGroup, default: []].append(Self.shaderPrimitive(rect))
                opacityByGroup[rect.compositeGroup] = rect.compositeOpacity
            }

            var allGroups = Set<Int>()
            allGroups.formUnion(trianglesByGroup.keys)
            allGroups.formUnion(linesByGroup.keys)
            allGroups.formUnion(rectsByGroup.keys)

            let sortedGroups = allGroups.sorted()
            compositeBatchBuffers = sortedGroups.map { group in
                let batch = compositeBatchStorageByGroup[group] ?? HorizontalMetalCompositeBatchBuffers(group: group)
                compositeBatchStorageByGroup[group] = batch
                batch.opacity = min(max(opacityByGroup[group] ?? 1, 0), 1)
                batch.replaceBuffers(
                    device: device,
                    triangles: trianglesByGroup[group] ?? [],
                    lines: linesByGroup[group] ?? [],
                    anchoredRects: rectsByGroup[group] ?? []
                )
                return batch
            }
            compositeBatchStorageByGroup = compositeBatchStorageByGroup.filter { allGroups.contains($0.key) }
        }

        private static func shaderPrimitive(_ line: HorizontalMetalLinePrimitive) -> HorizontalMetalLineShaderPrimitive {
            HorizontalMetalLineShaderPrimitive(
                from: SIMD2(Float(line.from.x), Float(line.from.y)),
                to: SIMD2(Float(line.to.x), Float(line.to.y)),
                color: line.color.simd,
                width: Float(line.width),
                minimumWidth: line.minimumWidth,
                dashLength: line.dashLength,
                dashGap: line.dashGap,
                normalOffset: line.normalOffset,
                outlineOnly: line.outlineOnly ? 1 : 0
            )
        }

        private static func shaderPrimitive(_ triangle: HorizontalMetalTrianglePrimitive) -> HorizontalMetalTriangleShaderPrimitive {
            HorizontalMetalTriangleShaderPrimitive(
                a: SIMD2(Float(triangle.a.x), Float(triangle.a.y)),
                b: SIMD2(Float(triangle.b.x), Float(triangle.b.y)),
                c: SIMD2(Float(triangle.c.x), Float(triangle.c.y)),
                color: triangle.color.simd
            )
        }

        private static func shaderPrimitive(_ rect: HorizontalMetalAnchoredRectPrimitive) -> HorizontalMetalAnchoredRectShaderPrimitive {
            HorizontalMetalAnchoredRectShaderPrimitive(
                center: SIMD2(Float(rect.center.x), Float(rect.center.y)),
                color: rect.color.simd,
                size: SIMD2(rect.width, rect.height)
            )
        }

        private static func shaderPrimitive(_ handle: HorizontalMetalHandlePrimitive) -> HorizontalMetalHandleShaderPrimitive {
            HorizontalMetalHandleShaderPrimitive(
                center: SIMD2(Float(handle.center.x), Float(handle.center.y)),
                outerColor: handle.outerColor.simd,
                innerColor: handle.innerColor.simd,
                outerRadius: handle.outerRadius,
                innerRadius: handle.innerRadius,
                shape: handle.shape.metalValue
            )
        }

        private func applyBufferPatches(_ patches: HorizontalMetalBufferPatches, key: Int) {
            guard currentBufferPatchKey != key else {
                return
            }
            currentBufferPatchKey = key
            guard !patches.isEmpty else {
                return
            }

            for patch in patches.linePatches {
                let primitives = patch.primitives.map(Self.shaderPrimitive)
                if patch.compositeGroup == 0 {
                    lineBufferStorage.replaceSubrange(start: patch.start, primitives: primitives)
                } else {
                    compositeBatchStorageByGroup[patch.compositeGroup]?.replaceLineSubrange(
                        start: patch.start,
                        primitives: primitives
                    )
                }
            }

            for patch in patches.trianglePatches {
                let primitives = patch.primitives.map(Self.shaderPrimitive)
                if patch.compositeGroup == 0 {
                    triangleBufferStorage.replaceSubrange(start: patch.start, primitives: primitives)
                } else {
                    compositeBatchStorageByGroup[patch.compositeGroup]?.replaceTriangleSubrange(
                        start: patch.start,
                        primitives: primitives
                    )
                }
            }

            for patch in patches.anchoredRectPatches {
                let primitives = patch.primitives.map(Self.shaderPrimitive)
                if patch.compositeGroup == 0 {
                    anchoredRectBufferStorage.replaceSubrange(start: patch.start, primitives: primitives)
                } else {
                    compositeBatchStorageByGroup[patch.compositeGroup]?.replaceAnchoredRectSubrange(
                        start: patch.start,
                        primitives: primitives
                    )
                }
            }

            for patch in patches.handlePatches {
                let primitives = patch.primitives.map(Self.shaderPrimitive)
                handleBufferStorage.replaceSubrange(start: patch.start, primitives: primitives)
            }

            for patch in patches.lineTranslationPatches {
                let delta = incrementalTranslationDelta(
                    kind: 0,
                    compositeGroup: patch.compositeGroup,
                    start: patch.start,
                    count: patch.count,
                    absoluteDelta: patch.delta
                )
                guard delta != .zero else { continue }
                if patch.compositeGroup == 0 {
                    translateLineSubrange(start: patch.start, count: patch.count, by: delta)
                } else {
                    compositeBatchStorageByGroup[patch.compositeGroup]?.translateLineSubrange(
                        start: patch.start,
                        count: patch.count,
                        by: delta
                    )
                }
            }

            for patch in patches.lineEndpointPatches {
                if patch.compositeGroup == 0 {
                    setLineEndpointSubrange(start: patch.start, from: patch.from, to: patch.to)
                } else {
                    compositeBatchStorageByGroup[patch.compositeGroup]?.setLineEndpointSubrange(
                        start: patch.start,
                        from: Self.shaderPoint(patch.from),
                        to: Self.shaderPoint(patch.to)
                    )
                }
            }

            for patch in patches.triangleTranslationPatches {
                let delta = incrementalTranslationDelta(
                    kind: 1,
                    compositeGroup: patch.compositeGroup,
                    start: patch.start,
                    count: patch.count,
                    absoluteDelta: patch.delta
                )
                guard delta != .zero else { continue }
                if patch.compositeGroup == 0 {
                    translateTriangleSubrange(start: patch.start, count: patch.count, by: delta)
                } else {
                    compositeBatchStorageByGroup[patch.compositeGroup]?.translateTriangleSubrange(
                        start: patch.start,
                        count: patch.count,
                        by: delta
                    )
                }
            }

            for patch in patches.anchoredRectTranslationPatches {
                let delta = incrementalTranslationDelta(
                    kind: 2,
                    compositeGroup: patch.compositeGroup,
                    start: patch.start,
                    count: patch.count,
                    absoluteDelta: patch.delta
                )
                guard delta != .zero else { continue }
                if patch.compositeGroup == 0 {
                    translateAnchoredRectSubrange(start: patch.start, count: patch.count, by: delta)
                } else {
                    compositeBatchStorageByGroup[patch.compositeGroup]?.translateAnchoredRectSubrange(
                        start: patch.start,
                        count: patch.count,
                        by: delta
                    )
                }
            }

            for patch in patches.handleTranslationPatches {
                let delta = incrementalTranslationDelta(
                    kind: 3,
                    compositeGroup: 0,
                    start: patch.start,
                    count: patch.count,
                    absoluteDelta: patch.delta
                )
                guard delta != .zero else { continue }
                translateHandleSubrange(start: patch.start, count: patch.count, by: delta)
            }
        }

        private func resetIncrementalBufferPatchState() {
            currentBufferPatchKey = nil
            appliedTranslationDeltas.removeAll(keepingCapacity: true)
        }

        private func incrementalTranslationDelta(
            kind: Int,
            compositeGroup: Int,
            start: Int,
            count: Int,
            absoluteDelta: HorizontalPoint
        ) -> SIMD2<Float> {
            let key = HorizontalMetalTranslationPatchKey(
                kind: kind,
                compositeGroup: compositeGroup,
                start: start,
                count: count
            )
            let absolute = SIMD2(Float(absoluteDelta.x), Float(absoluteDelta.y))
            let previous = appliedTranslationDeltas[key] ?? .zero
            appliedTranslationDeltas[key] = absolute
            return absolute - previous
        }

        private static func shaderPoint(_ point: HorizontalPoint?) -> SIMD2<Float>? {
            point.map { SIMD2(Float($0.x), Float($0.y)) }
        }

        private func translateLineSubrange(start: Int, count: Int, by delta: SIMD2<Float>) {
            lineBufferStorage.mutateSubrange(start: start, count: count) { primitives in
                for index in primitives.indices {
                    primitives[index].from += delta
                    primitives[index].to += delta
                }
            }
        }

        private func setLineEndpointSubrange(start: Int, from: HorizontalPoint?, to: HorizontalPoint?) {
            let shaderFrom = Self.shaderPoint(from)
            let shaderTo = Self.shaderPoint(to)
            lineBufferStorage.mutateSubrange(start: start, count: 1) { primitives in
                guard let index = primitives.indices.first else {
                    return
                }
                if let shaderFrom {
                    primitives[index].from = shaderFrom
                }
                if let shaderTo {
                    primitives[index].to = shaderTo
                }
            }
        }

        private func translateTriangleSubrange(start: Int, count: Int, by delta: SIMD2<Float>) {
            triangleBufferStorage.mutateSubrange(start: start, count: count) { primitives in
                for index in primitives.indices {
                    primitives[index].a += delta
                    primitives[index].b += delta
                    primitives[index].c += delta
                }
            }
        }

        private func translateAnchoredRectSubrange(start: Int, count: Int, by delta: SIMD2<Float>) {
            anchoredRectBufferStorage.mutateSubrange(start: start, count: count) { primitives in
                for index in primitives.indices {
                    primitives[index].center += delta
                }
            }
        }

        private func translateHandleSubrange(start: Int, count: Int, by delta: SIMD2<Float>) {
            handleBufferStorage.mutateSubrange(start: start, count: count) { primitives in
                for index in primitives.indices {
                    primitives[index].center += delta
                }
            }
        }

        /// Layer-group batches that are visible and contribute color this frame.
        private func activeCompositeBatches() -> [HorizontalMetalCompositeBatchBuffers] {
            compositeBatchBuffers.filter { batch in
                guard !batch.isEmpty, batch.opacity > 0 else {
                    return false
                }
                return currentVisibleCompositeGroups?.contains(batch.group) ?? true
            }
        }

        /// Draws fully-opaque layer groups directly into the main pass instead of
        /// rendering each to its own offscreen texture and compositing. Only used
        /// when every active group's effective opacity is 1, where this is
        /// pixel-identical to compositing (src-over is associative).
        private func encodeInlineCompositeGroups(
            _ batches: [HorizontalMetalCompositeBatchBuffers],
            encoder: MTLRenderCommandEncoder
        ) {
            for batch in batches {
                if let trianglePipelineState, let buffer = batch.triangleBuffer, batch.triangleCount > 0 {
                    encoder.setRenderPipelineState(trianglePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.triangleCount * 3)
                }
                if let linePipelineState, let buffer = batch.lineBuffer, batch.lineCount > 0 {
                    encoder.setRenderPipelineState(linePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.lineCount * 6)
                }
                if let anchoredRectPipelineState, let buffer = batch.anchoredRectBuffer, batch.anchoredRectCount > 0 {
                    encoder.setRenderPipelineState(anchoredRectPipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.anchoredRectCount * 6)
                }
            }
        }

        private func renderCompositeTextures(
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize
        ) -> [HorizontalMetalCompositeTexture] {
            let activeBatches = activeCompositeBatches()
            guard let device,
                  !activeBatches.isEmpty,
                  let offscreenTrianglePipelineState,
                  let offscreenLinePipelineState,
                  let offscreenAnchoredRectPipelineState else {
                return []
            }

            let pixelSize = CGSize(
                width: max(drawableSize.width.rounded(.down), 1),
                height: max(drawableSize.height.rounded(.down), 1)
            )
            ensureCompositeTextures(device: device, count: activeBatches.count, size: pixelSize)

            var result = [HorizontalMetalCompositeTexture]()
            for (index, batch) in activeBatches.enumerated() {
                guard compositeRenderTextures.indices.contains(index) else {
                    continue
                }
                let texture = compositeRenderTextures[index]
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = texture
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                descriptor.colorAttachments[0].storeAction = .store

                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                    continue
                }

                if let triangleBuffer = batch.triangleBuffer, batch.triangleCount > 0 {
                    encoder.setRenderPipelineState(offscreenTrianglePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(triangleBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.triangleCount * 3)
                }

                if let lineBuffer = batch.lineBuffer, batch.lineCount > 0 {
                    encoder.setRenderPipelineState(offscreenLinePipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(lineBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.lineCount * 6)
                }

                if let anchoredRectBuffer = batch.anchoredRectBuffer, batch.anchoredRectCount > 0 {
                    encoder.setRenderPipelineState(offscreenAnchoredRectPipelineState)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<HorizontalMetalBackdropUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(anchoredRectBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.anchoredRectCount * 6)
                }

                encoder.endEncoding()
                result.append(HorizontalMetalCompositeTexture(
                    texture: texture,
                    opacity: batch.opacity,
                    ignoresLayerOpacity: currentLayerOpacityExemptCompositeGroups.contains(batch.group)
                ))
            }

            return result
        }

        private func ensureCompositeTextures(device: MTLDevice, count: Int, size: CGSize) {
            guard currentCompositeTextureSize != size || compositeRenderTextures.count < count else {
                return
            }

            currentCompositeTextureSize = size
            compositeRenderTextures = (0..<count).compactMap { _ in
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: Int(size.width),
                    height: Int(size.height),
                    mipmapped: false
                )
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                return device.makeTexture(descriptor: descriptor)
            }
        }

        private func updateUniforms(viewport: CanvasViewport) {
            uniforms.viewportSize = max(currentViewportSize, SIMD2<Float>(1, 1))
            uniforms.backingScale = max(currentBackingScale, 1)

            var effectiveSpacing = currentGrid?.spacing ?? .zero
            let fitScale = Self.fitScale(bounds: currentBounds, drawableSize: uniforms.viewportSize, fitInsets: currentFitInsets)
            let scale = Double(fitScale * Float(max(viewport.zoom, 0.01)))
            while effectiveSpacing.x > 0,
                  effectiveSpacing.y > 0,
                  (effectiveSpacing.x * scale < 20 || effectiveSpacing.y * scale < 20) {
                effectiveSpacing = effectiveSpacing * 2
            }

            uniforms.boundsMin = SIMD2(Float(currentBounds.minX), Float(currentBounds.minY))
            uniforms.boundsMax = SIMD2(Float(currentBounds.maxX), Float(currentBounds.maxY))
            uniforms.pan = SIMD2(Float(viewport.pan.width), Float(viewport.pan.height))
            uniforms.zoom = Float(max(viewport.zoom, 0.01))
            uniforms.fitInsets = SIMD4(
                Float(currentFitInsets.top),
                Float(currentFitInsets.leading),
                Float(currentFitInsets.bottom),
                Float(currentFitInsets.trailing)
            )
            uniforms.gridSpacing = SIMD2(Float(effectiveSpacing.x), Float(effectiveSpacing.y))
            uniforms.gridOrigin = SIMD2(Float(currentGrid?.origin.x ?? 0), Float(currentGrid?.origin.y ?? 0))
            uniforms.backgroundColor = Self.rgba(currentBackgroundColor)
            uniforms.gridColor = Self.rgba(currentGridColor)
            uniforms.minimumLineWidth = max(currentMinimumLineWidth, 0)
            uniforms.gridLineWidth = max(currentGridLineWidth, 0)
            uniforms.minimumScreenSpacing = 20
            uniforms.markSize = 5
            uniforms.showGrid = currentGrid == nil || effectiveSpacing.x <= 0 || effectiveSpacing.y <= 0 ? 0 : 1
        }

        private static func makeTrianglePipelineState(
            device: MTLDevice,
            pixelFormat: MTLPixelFormat,
            sampleCount: Int
        ) -> MTLRenderPipelineState? {
            guard let library = HorizontalMetalLibraryCache.library(for: device) else {
                return nil
            }
            do {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "horizon_triangle_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "horizon_triangle_fragment")
                descriptor.rasterSampleCount = sampleCount
                let attachment = descriptor.colorAttachments[0]
                attachment?.pixelFormat = pixelFormat
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .sourceAlpha
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Horizontal Metal triangle pipeline failed: \(error)")
                return nil
            }
        }

        private static func makeBackdropPipelineState(
            device: MTLDevice,
            pixelFormat: MTLPixelFormat,
            sampleCount: Int
        ) -> MTLRenderPipelineState? {
            guard let library = HorizontalMetalLibraryCache.library(for: device) else {
                return nil
            }
            do {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "horizon_backdrop_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "horizon_backdrop_fragment")
                descriptor.rasterSampleCount = sampleCount
                descriptor.colorAttachments[0].pixelFormat = pixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Horizontal Metal backdrop pipeline failed: \(error)")
                return nil
            }
        }

        private static func makeLinePipelineState(
            device: MTLDevice,
            pixelFormat: MTLPixelFormat,
            sampleCount: Int
        ) -> MTLRenderPipelineState? {
            guard let library = HorizontalMetalLibraryCache.library(for: device) else {
                return nil
            }
            do {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "horizon_line_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "horizon_line_fragment")
                descriptor.rasterSampleCount = sampleCount
                let attachment = descriptor.colorAttachments[0]
                attachment?.pixelFormat = pixelFormat
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .sourceAlpha
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Horizontal Metal line pipeline failed: \(error)")
                return nil
            }
        }

        private static func makeHandlePipelineState(
            device: MTLDevice,
            pixelFormat: MTLPixelFormat,
            sampleCount: Int
        ) -> MTLRenderPipelineState? {
            guard let library = HorizontalMetalLibraryCache.library(for: device) else {
                return nil
            }
            do {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "horizon_handle_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "horizon_handle_fragment")
                descriptor.rasterSampleCount = sampleCount
                let attachment = descriptor.colorAttachments[0]
                attachment?.pixelFormat = pixelFormat
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .sourceAlpha
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Horizontal Metal handle pipeline failed: \(error)")
                return nil
            }
        }

        private static func makeAnchoredRectPipelineState(
            device: MTLDevice,
            pixelFormat: MTLPixelFormat,
            sampleCount: Int
        ) -> MTLRenderPipelineState? {
            guard let library = HorizontalMetalLibraryCache.library(for: device) else {
                return nil
            }
            do {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "horizon_anchored_rect_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "horizon_triangle_fragment")
                descriptor.rasterSampleCount = sampleCount
                let attachment = descriptor.colorAttachments[0]
                attachment?.pixelFormat = pixelFormat
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .sourceAlpha
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Horizontal Metal anchored-rect pipeline failed: \(error)")
                return nil
            }
        }

        private static func makeScreenTrianglePipelineState(
            device: MTLDevice,
            pixelFormat: MTLPixelFormat,
            sampleCount: Int
        ) -> MTLRenderPipelineState? {
            guard let library = HorizontalMetalLibraryCache.library(for: device) else {
                return nil
            }
            do {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "horizon_screen_triangle_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "horizon_triangle_fragment")
                descriptor.rasterSampleCount = sampleCount
                let attachment = descriptor.colorAttachments[0]
                attachment?.pixelFormat = pixelFormat
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .sourceAlpha
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Horizontal Metal screen-triangle pipeline failed: \(error)")
                return nil
            }
        }

        private static func makeScreenLinePipelineState(
            device: MTLDevice,
            pixelFormat: MTLPixelFormat,
            sampleCount: Int
        ) -> MTLRenderPipelineState? {
            guard let library = HorizontalMetalLibraryCache.library(for: device) else {
                return nil
            }
            do {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "horizon_screen_line_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "horizon_line_fragment")
                descriptor.rasterSampleCount = sampleCount
                let attachment = descriptor.colorAttachments[0]
                attachment?.pixelFormat = pixelFormat
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .sourceAlpha
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Horizontal Metal screen-line pipeline failed: \(error)")
                return nil
            }
        }

        private static func makeTextureCompositePipelineState(
            device: MTLDevice,
            pixelFormat: MTLPixelFormat,
            sampleCount: Int
        ) -> MTLRenderPipelineState? {
            guard let library = HorizontalMetalLibraryCache.library(for: device) else {
                return nil
            }
            do {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "horizon_texture_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "horizon_texture_fragment")
                descriptor.rasterSampleCount = sampleCount
                let attachment = descriptor.colorAttachments[0]
                attachment?.pixelFormat = pixelFormat
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .one
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Horizontal Metal texture-composite pipeline failed: \(error)")
                return nil
            }
        }

        private static func fitScale(
            bounds: HorizontalRect,
            drawableSize: SIMD2<Float>,
            fitInsets: HorizontalCanvasInsets
        ) -> Float {
            guard !bounds.isEmpty else {
                return 1
            }
            let availableWidth = max(drawableSize.x - Float(fitInsets.leading + fitInsets.trailing), 1)
            let availableHeight = max(drawableSize.y - Float(fitInsets.top + fitInsets.bottom), 1)
            return min(availableWidth / Float(bounds.width), availableHeight / Float(bounds.height))
        }

        private static func rgba(_ color: Color) -> SIMD4<Float> {
            #if canImport(AppKit)
            let nsColor = NSColor(color)
            let rgba = nsColor.usingColorSpace(.deviceRGB) ?? nsColor.usingColorSpace(.sRGB) ?? .black
            return SIMD4(
                Float(rgba.redComponent),
                Float(rgba.greenComponent),
                Float(rgba.blueComponent),
                Float(rgba.alphaComponent)
            )
            #elseif canImport(UIKit)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
            #endif
        }
    }
}

// Per-platform SwiftUI representable conformance. Both forward to the shared
// make/update logic; MTKView is the backing view on macOS (NSView) and iOS (UIView).
#if os(macOS)
extension HorizontalMetalBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        makeBackdropView(coordinator: context.coordinator)
    }

    func updateNSView(_ view: MTKView, context: Context) {
        updateBackdropView(view, coordinator: context.coordinator)
    }
}
#elseif os(iOS)
extension HorizontalMetalBackdropView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        makeBackdropView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: MTKView, context: Context) {
        updateBackdropView(view, coordinator: context.coordinator)
    }
}
#endif

@MainActor
final class HorizontalCanvasViewportDriver {
    private struct Sink {
        weak var renderer: HorizontalMetalBackdropView.Renderer?
        weak var view: MTKView?
    }

    private var sinks = [Sink]()
    private var viewportSyncTask: Task<Void, Never>?
    private var liveViewportSyncTask: Task<Void, Never>?
    private var pendingLiveViewport: CanvasViewport?

    private(set) var viewport = CanvasViewport()
    private(set) var isConfigured = false
    var onSettledViewportChange: ((CanvasViewport) -> Void)?
    var onLiveViewportChange: ((CanvasViewport) -> Void)?

    func configure(
        viewport: CanvasViewport,
        onSettledViewportChange: ((CanvasViewport) -> Void)? = nil,
        onLiveViewportChange: ((CanvasViewport) -> Void)? = nil
    ) {
        if let onSettledViewportChange {
            self.onSettledViewportChange = onSettledViewportChange
        }
        if let onLiveViewportChange {
            self.onLiveViewportChange = onLiveViewportChange
        }
        isConfigured = true
        guard self.viewport != viewport else {
            return
        }
        self.viewport = viewport
        updateSinks()
        publishLiveViewport()
    }

    func update(_ update: (inout CanvasViewport) -> Void) {
        var nextViewport = viewport
        update(&nextViewport)
        guard nextViewport != viewport else {
            return
        }

        viewport = nextViewport
        updateSinks()
        scheduleLiveViewportSync()
        scheduleSettledSync()
    }

    func flush() {
        liveViewportSyncTask?.cancel()
        liveViewportSyncTask = nil
        pendingLiveViewport = nil
        onLiveViewportChange?(viewport)
        viewportSyncTask?.cancel()
        viewportSyncTask = nil
        onSettledViewportChange?(viewport)
    }

    func register(renderer: HorizontalMetalBackdropView.Renderer, view: MTKView) {
        sinks.removeAll { sink in
            guard let existingRenderer = sink.renderer,
                  let existingView = sink.view else {
                return true
            }
            return existingRenderer === renderer || existingView === view
        }
        sinks.append(Sink(renderer: renderer, view: view))
        renderer.updateLiveViewport(viewport)
        #if os(macOS)
        view.needsDisplay = true
        view.setNeedsDisplay(view.bounds)
        #else
        view.setNeedsDisplay()
        #endif
    }

    private func scheduleSettledSync() {
        // Pushing the viewport back into the @Binding chain re-renders the
        // parent (ProjectDocumentView), which then re-renders BoardCanvasView
        // with new closure args ("@self changed"). At 150 ms this fired during
        // brief mid-interaction pauses and caused visible draw-rate dips. 600 ms
        // means it only fires after the user has truly stopped — chrome and
        // saving still get the value, just a beat later.
        viewportSyncTask?.cancel()
        viewportSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else {
                return
            }
            onSettledViewportChange?(viewport)
            viewportSyncTask = nil
        }
    }

    private func scheduleLiveViewportSync() {
        pendingLiveViewport = viewport
        guard liveViewportSyncTask == nil else {
            return
        }

        liveViewportSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else {
                return
            }
            if let pendingLiveViewport {
                onLiveViewportChange?(pendingLiveViewport)
                self.pendingLiveViewport = nil
            }
            liveViewportSyncTask = nil
        }
    }

    private func publishLiveViewport() {
        liveViewportSyncTask?.cancel()
        liveViewportSyncTask = nil
        pendingLiveViewport = nil
        onLiveViewportChange?(viewport)
    }

    private func updateSinks() {
        sinks.removeAll { sink in
            guard let renderer = sink.renderer,
                  let view = sink.view else {
                return true
            }
            renderer.updateLiveViewport(viewport)
            #if os(macOS)
            view.needsDisplay = true
            view.setNeedsDisplay(view.bounds)
            #else
            view.setNeedsDisplay()
            #endif
            return false
        }
    }
}

private struct HorizontalMetalBackdropUniforms {
    var viewportSize = SIMD2<Float>(1, 1)
    var boundsMin = SIMD2<Float>(0, 0)
    var boundsMax = SIMD2<Float>(1, 1)
    var pan = SIMD2<Float>(0, 0)
    var fitInsets = SIMD4<Float>(0, 0, 0, 0)
    var gridSpacing = SIMD2<Float>(0, 0)
    var gridOrigin = SIMD2<Float>(0, 0)
    var backgroundColor = SIMD4<Float>(0, 0, 0, 1)
    var gridColor = SIMD4<Float>(0, 0, 0, 0)
    var zoom: Float = 1
    var minimumScreenSpacing: Float = 20
    var markSize: Float = 5
    var showGrid: Float = 0
    var gridLineWidth: Float = 0.5
    var minimumLineWidth: Float = 0
    var backingScale: Float = 1
    var padding = SIMD2<Float>(0, 0)
}

private struct HorizontalMetalLineShaderPrimitive {
    var from: SIMD2<Float>
    var to: SIMD2<Float>
    var color: SIMD4<Float>
    var width: Float
    var minimumWidth: Float
    var dashLength: Float
    var dashGap: Float
    var normalOffset: Float
    var outlineOnly: Float
    var padding = SIMD2<Float>(0, 0)
}

private struct HorizontalMetalTriangleShaderPrimitive {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var c: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct HorizontalMetalTranslationPatchKey: Hashable {
    var kind: Int
    var compositeGroup: Int
    var start: Int
    var count: Int
}

private struct HorizontalMetalHandleShaderPrimitive {
    var center: SIMD2<Float>
    var outerColor: SIMD4<Float>
    var innerColor: SIMD4<Float>
    var outerRadius: Float
    var innerRadius: Float
    var shape: Float
    var padding = SIMD3<Float>(0, 0, 0)
}

private struct HorizontalMetalAnchoredRectShaderPrimitive {
    var center: SIMD2<Float>
    var color: SIMD4<Float>
    var size: SIMD2<Float>
}

private struct HorizontalMetalScreenLineShaderPrimitive {
    var from: SIMD2<Float>
    var to: SIMD2<Float>
    var color: SIMD4<Float>
    var width: Float
    var dashLength: Float
    var dashGap: Float
    var padding: Float
}

private struct HorizontalMetalScreenTriangleShaderPrimitive {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var c: SIMD2<Float>
    var color: SIMD4<Float>
}

private final class HorizontalMetalBufferStorage<Element> {
    private(set) var buffer: MTLBuffer?
    private var capacity = 0
    private var activeByteCount = 0

    func replace(device: MTLDevice, primitives: [Element]) -> MTLBuffer? {
        guard !primitives.isEmpty else {
            activeByteCount = 0
            return nil
        }

        let byteCount = MemoryLayout<Element>.stride * primitives.count
        if buffer == nil || capacity < byteCount {
            capacity = Self.nextCapacity(for: byteCount, current: capacity)
            buffer = device.makeBuffer(length: capacity, options: .storageModeShared)
        }
        activeByteCount = byteCount

        primitives.withUnsafeBytes { source in
            guard let sourceBaseAddress = source.baseAddress,
                  let destinationBaseAddress = buffer?.contents() else {
                return
            }
            destinationBaseAddress.copyMemory(from: sourceBaseAddress, byteCount: source.count)
        }
        finishWrites()
        return buffer
    }

    func replaceSubrange(start: Int, primitives: [Element]) {
        guard start >= 0,
              !primitives.isEmpty,
              let buffer else {
            return
        }

        let stride = MemoryLayout<Element>.stride
        let offset = start * stride
        let byteCount = primitives.count * stride
        guard offset + byteCount <= activeByteCount else {
            return
        }

        primitives.withUnsafeBytes { source in
            guard let sourceBaseAddress = source.baseAddress else {
                return
            }
            buffer.contents().advanced(by: offset).copyMemory(
                from: sourceBaseAddress,
                byteCount: source.count
            )
        }
        // .storageModeManaged + didModifyRange are macOS-only; iOS buffers are
        // .storageModeShared (unified memory) and need no explicit flush.
        #if os(macOS)
        if buffer.storageMode == .managed {
            buffer.didModifyRange(offset..<(offset + byteCount))
        }
        #endif
    }

    func mutateSubrange(start: Int, count: Int, _ mutate: (UnsafeMutableBufferPointer<Element>) -> Void) {
        guard start >= 0,
              count > 0,
              let buffer else {
            return
        }

        let stride = MemoryLayout<Element>.stride
        let offset = start * stride
        let byteCount = count * stride
        guard offset + byteCount <= activeByteCount else {
            return
        }

        let pointer = buffer.contents()
            .advanced(by: offset)
            .bindMemory(to: Element.self, capacity: count)
        mutate(UnsafeMutableBufferPointer(start: pointer, count: count))
        #if os(macOS)
        if buffer.storageMode == .managed {
            buffer.didModifyRange(offset..<(offset + byteCount))
        }
        #endif
    }

    private func finishWrites() {
        // Managed-buffer flush is macOS-only; iOS shared buffers are coherent.
        #if os(macOS)
        guard activeByteCount > 0,
              buffer?.storageMode == .managed else {
            return
        }
        buffer?.didModifyRange(0..<activeByteCount)
        #endif
    }

    private static func nextCapacity(for byteCount: Int, current: Int) -> Int {
        var capacity = max(current, 16 * 1024)
        while capacity < byteCount {
            capacity *= 2
        }
        return capacity
    }
}

private final class HorizontalMetalCompositeBatchBuffers {
    let group: Int
    var opacity: Float = 1
    private var triangleStorage = HorizontalMetalBufferStorage<HorizontalMetalTriangleShaderPrimitive>()
    private var lineStorage = HorizontalMetalBufferStorage<HorizontalMetalLineShaderPrimitive>()
    private var anchoredRectStorage = HorizontalMetalBufferStorage<HorizontalMetalAnchoredRectShaderPrimitive>()
    private(set) var triangleCount = 0
    private(set) var lineCount = 0
    private(set) var anchoredRectCount = 0

    init(group: Int) {
        self.group = group
    }

    var triangleBuffer: MTLBuffer? {
        triangleStorage.buffer
    }

    var lineBuffer: MTLBuffer? {
        lineStorage.buffer
    }

    var anchoredRectBuffer: MTLBuffer? {
        anchoredRectStorage.buffer
    }

    var isEmpty: Bool {
        triangleCount == 0 && lineCount == 0 && anchoredRectCount == 0
    }

    func replaceBuffers(
        device: MTLDevice,
        triangles: [HorizontalMetalTriangleShaderPrimitive],
        lines: [HorizontalMetalLineShaderPrimitive],
        anchoredRects: [HorizontalMetalAnchoredRectShaderPrimitive]
    ) {
        triangleCount = triangles.count
        lineCount = lines.count
        anchoredRectCount = anchoredRects.count
        _ = triangleStorage.replace(device: device, primitives: triangles)
        _ = lineStorage.replace(device: device, primitives: lines)
        _ = anchoredRectStorage.replace(device: device, primitives: anchoredRects)
    }

    func replaceTriangleSubrange(start: Int, primitives: [HorizontalMetalTriangleShaderPrimitive]) {
        triangleStorage.replaceSubrange(start: start, primitives: primitives)
    }

    func replaceLineSubrange(start: Int, primitives: [HorizontalMetalLineShaderPrimitive]) {
        lineStorage.replaceSubrange(start: start, primitives: primitives)
    }

    func replaceAnchoredRectSubrange(start: Int, primitives: [HorizontalMetalAnchoredRectShaderPrimitive]) {
        anchoredRectStorage.replaceSubrange(start: start, primitives: primitives)
    }

    func translateTriangleSubrange(start: Int, count: Int, by delta: SIMD2<Float>) {
        triangleStorage.mutateSubrange(start: start, count: count) { primitives in
            for index in primitives.indices {
                primitives[index].a += delta
                primitives[index].b += delta
                primitives[index].c += delta
            }
        }
    }

    func translateLineSubrange(start: Int, count: Int, by delta: SIMD2<Float>) {
        lineStorage.mutateSubrange(start: start, count: count) { primitives in
            for index in primitives.indices {
                primitives[index].from += delta
                primitives[index].to += delta
            }
        }
    }

    func setLineEndpointSubrange(start: Int, from: SIMD2<Float>?, to: SIMD2<Float>?) {
        lineStorage.mutateSubrange(start: start, count: 1) { primitives in
            guard let index = primitives.indices.first else {
                return
            }
            if let from {
                primitives[index].from = from
            }
            if let to {
                primitives[index].to = to
            }
        }
    }

    func translateAnchoredRectSubrange(start: Int, count: Int, by delta: SIMD2<Float>) {
        anchoredRectStorage.mutateSubrange(start: start, count: count) { primitives in
            for index in primitives.indices {
                primitives[index].center += delta
            }
        }
    }
}

private struct HorizontalMetalCompositeTexture {
    var texture: MTLTexture
    var opacity: Float
    /// When true this texture composites at `opacity` directly, unaffected by the
    /// layer-opacity slider (the overlay-label group; see
    /// currentLayerOpacityExemptCompositeGroups).
    var ignoresLayerOpacity: Bool = false
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct HorizontalMetalBackdropUniforms {
    float2 viewportSize;
    float2 boundsMin;
    float2 boundsMax;
    float2 pan;
    float4 fitInsets;
    float2 gridSpacing;
    float2 gridOrigin;
    float4 backgroundColor;
    float4 gridColor;
    float zoom;
    float minimumScreenSpacing;
    float markSize;
    float showGrid;
    float gridLineWidth;
    float minimumLineWidth;
    float backingScale;
    float2 padding;
};

struct BackdropVertexOut {
    float4 position [[position]];
};

struct HorizontalMetalLinePrimitive {
    float2 from;
    float2 to;
    float4 color;
    float width;
    float minimumWidth;
    float dashLength;
    float dashGap;
    float normalOffset;
    float outlineOnly;
    float2 padding;
};

struct HorizontalMetalTrianglePrimitive {
    float2 a;
    float2 b;
    float2 c;
    float4 color;
};

struct HorizontalMetalHandlePrimitive {
    float2 center;
    float4 outerColor;
    float4 innerColor;
    float outerRadius;
    float innerRadius;
    float shape;
    float3 padding;
};

struct HorizontalMetalAnchoredRectPrimitive {
    float2 center;
    float4 color;
    float2 size;
};

struct HorizontalMetalScreenLinePrimitive {
    float2 from;
    float2 to;
    float4 color;
    float width;
    float dashLength;
    float dashGap;
    float padding;
};

struct HorizontalMetalScreenTrianglePrimitive {
    float2 a;
    float2 b;
    float2 c;
    float4 color;
};

struct TriangleVertexOut {
    float4 position [[position]];
    float4 color;
};

struct LineVertexOut {
    float4 position [[position]];
    float2 screenPosition;
    float2 start;
    float2 end;
    float4 color;
    float halfWidth;
    float dashLength;
    float dashGap;
    float outlineOnly;
};

struct HandleVertexOut {
    float4 position [[position]];
    float2 localPosition;
    float4 outerColor;
    float4 innerColor;
    float outerRadius;
    float innerRadius;
    float shape;
};

struct TextureVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

float horizon_fit_scale(constant HorizontalMetalBackdropUniforms& uniforms) {
    float2 viewportSize = max(uniforms.viewportSize, float2(1.0));
    float2 boundsSize = max(uniforms.boundsMax - uniforms.boundsMin, float2(1.0));
    float availableWidth = max(viewportSize.x - uniforms.fitInsets.y - uniforms.fitInsets.w, 1.0);
    float availableHeight = max(viewportSize.y - uniforms.fitInsets.x - uniforms.fitInsets.z, 1.0);
    return min(availableWidth / boundsSize.x, availableHeight / boundsSize.y);
}

float horizon_scale(constant HorizontalMetalBackdropUniforms& uniforms) {
    return horizon_fit_scale(uniforms) * max(uniforms.zoom, 0.01);
}

float2 horizon_screen_origin(constant HorizontalMetalBackdropUniforms& uniforms, float scale) {
    float2 viewportSize = max(uniforms.viewportSize, float2(1.0));
    float2 boundsSize = max(uniforms.boundsMax - uniforms.boundsMin, float2(1.0));
    float2 contentSize = boundsSize * scale;
    return (viewportSize - contentSize) * 0.5 + uniforms.pan;
}

float2 horizon_world_to_screen(float2 world, constant HorizontalMetalBackdropUniforms& uniforms, float scale, float2 screenOrigin) {
    return float2(
        screenOrigin.x + (world.x - uniforms.boundsMin.x) * scale,
        screenOrigin.y + (uniforms.boundsMax.y - world.y) * scale
    );
}

float4 horizon_screen_to_clip(float2 screen, constant HorizontalMetalBackdropUniforms& uniforms) {
    float2 viewportSize = max(uniforms.viewportSize, float2(1.0));
    return float4(
        screen.x / viewportSize.x * 2.0 - 1.0,
        1.0 - screen.y / viewportSize.y * 2.0,
        0.0,
        1.0
    );
}

vertex BackdropVertexOut horizon_backdrop_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    BackdropVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

vertex TextureVertexOut horizon_texture_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };

    TextureVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

vertex TriangleVertexOut horizon_triangle_vertex(
    uint vertexID [[vertex_id]],
    constant HorizontalMetalBackdropUniforms& uniforms [[buffer(0)]],
    device const HorizontalMetalTrianglePrimitive* triangles [[buffer(1)]]
) {
    uint triangleIndex = vertexID / 3;
    uint cornerIndex = vertexID % 3;
    HorizontalMetalTrianglePrimitive triangle = triangles[triangleIndex];

    float2 vertices[3] = {
        triangle.a,
        triangle.b,
        triangle.c
    };

    float scale = horizon_scale(uniforms);
    float2 origin = horizon_screen_origin(uniforms, scale);
    float2 screenPosition = horizon_world_to_screen(vertices[cornerIndex], uniforms, scale, origin);

    TriangleVertexOut out;
    out.position = horizon_screen_to_clip(screenPosition, uniforms);
    out.color = triangle.color;
    return out;
}

vertex TriangleVertexOut horizon_screen_triangle_vertex(
    uint vertexID [[vertex_id]],
    constant HorizontalMetalBackdropUniforms& uniforms [[buffer(0)]],
    device const HorizontalMetalScreenTrianglePrimitive* triangles [[buffer(1)]]
) {
    uint triangleIndex = vertexID / 3;
    uint cornerIndex = vertexID % 3;
    HorizontalMetalScreenTrianglePrimitive triangle = triangles[triangleIndex];

    float2 vertices[3] = {
        triangle.a,
        triangle.b,
        triangle.c
    };

    TriangleVertexOut out;
    out.position = horizon_screen_to_clip(vertices[cornerIndex], uniforms);
    out.color = triangle.color;
    return out;
}

vertex LineVertexOut horizon_line_vertex(
    uint vertexID [[vertex_id]],
    constant HorizontalMetalBackdropUniforms& uniforms [[buffer(0)]],
    device const HorizontalMetalLinePrimitive* lines [[buffer(1)]]
) {
    uint lineIndex = vertexID / 6;
    uint cornerIndex = vertexID % 6;
    HorizontalMetalLinePrimitive line = lines[lineIndex];

    float scale = horizon_scale(uniforms);
    float2 origin = horizon_screen_origin(uniforms, scale);
    float2 start = horizon_world_to_screen(line.from, uniforms, scale, origin);
    float2 end = horizon_world_to_screen(line.to, uniforms, scale, origin);
    float2 vector = end - start;
    float segmentLength = max(length(vector), 0.001);
    float2 axis = vector / segmentLength;
    float2 normal = float2(-axis.y, axis.x);
    float halfWidth = max(max(line.width * scale, line.minimumWidth), uniforms.minimumLineWidth) * 0.5;
    float tangentExtension = abs(line.normalOffset);
    start += normal * line.normalOffset - axis * tangentExtension;
    end += normal * line.normalOffset + axis * tangentExtension;
    float2 cap = axis * halfWidth;

    float2 corners[6] = {
        start - cap + normal * halfWidth,
        end + cap + normal * halfWidth,
        start - cap - normal * halfWidth,
        start - cap - normal * halfWidth,
        end + cap + normal * halfWidth,
        end + cap - normal * halfWidth
    };

    LineVertexOut out;
    float2 screenPosition = corners[cornerIndex];
    out.position = horizon_screen_to_clip(screenPosition, uniforms);
    out.screenPosition = screenPosition;
    out.start = start;
    out.end = end;
    out.color = line.color;
    out.halfWidth = halfWidth;
    out.dashLength = line.dashLength;
    out.dashGap = line.dashGap;
    out.outlineOnly = line.outlineOnly;
    return out;
}

vertex HandleVertexOut horizon_handle_vertex(
    uint vertexID [[vertex_id]],
    constant HorizontalMetalBackdropUniforms& uniforms [[buffer(0)]],
    device const HorizontalMetalHandlePrimitive* handles [[buffer(1)]]
) {
    uint handleIndex = vertexID / 6;
    uint cornerIndex = vertexID % 6;
    HorizontalMetalHandlePrimitive handle = handles[handleIndex];

    float radius = max(handle.outerRadius, 0.5);
    float2 corners[6] = {
        float2(-radius, -radius),
        float2( radius, -radius),
        float2(-radius,  radius),
        float2(-radius,  radius),
        float2( radius, -radius),
        float2( radius,  radius)
    };

    float scale = horizon_scale(uniforms);
    float2 origin = horizon_screen_origin(uniforms, scale);
    float2 center = horizon_world_to_screen(handle.center, uniforms, scale, origin);
    float2 localPosition = corners[cornerIndex];
    float2 screenPosition = center + localPosition;

    HandleVertexOut out;
    out.position = horizon_screen_to_clip(screenPosition, uniforms);
    out.localPosition = localPosition;
    out.outerColor = handle.outerColor;
    out.innerColor = handle.innerColor;
    out.outerRadius = radius;
    out.innerRadius = min(handle.innerRadius, radius);
    out.shape = handle.shape;
    return out;
}

vertex TriangleVertexOut horizon_anchored_rect_vertex(
    uint vertexID [[vertex_id]],
    constant HorizontalMetalBackdropUniforms& uniforms [[buffer(0)]],
    device const HorizontalMetalAnchoredRectPrimitive* rects [[buffer(1)]]
) {
    uint rectIndex = vertexID / 6;
    uint cornerIndex = vertexID % 6;
    HorizontalMetalAnchoredRectPrimitive rect = rects[rectIndex];

    float2 halfSize = max(rect.size, float2(0.0)) * 0.5;
    float2 corners[4] = {
        float2(-halfSize.x, -halfSize.y),
        float2( halfSize.x, -halfSize.y),
        float2( halfSize.x,  halfSize.y),
        float2(-halfSize.x,  halfSize.y)
    };
    uint indices[6] = { 0, 1, 2, 0, 2, 3 };

    float scale = horizon_scale(uniforms);
    float2 origin = horizon_screen_origin(uniforms, scale);
    float2 center = horizon_world_to_screen(rect.center, uniforms, scale, origin);
    float2 screenPosition = center + corners[indices[cornerIndex]];

    TriangleVertexOut out;
    out.position = horizon_screen_to_clip(screenPosition, uniforms);
    out.color = rect.color;
    return out;
}

vertex LineVertexOut horizon_screen_line_vertex(
    uint vertexID [[vertex_id]],
    constant HorizontalMetalBackdropUniforms& uniforms [[buffer(0)]],
    device const HorizontalMetalScreenLinePrimitive* lines [[buffer(1)]]
) {
    uint lineIndex = vertexID / 6;
    uint cornerIndex = vertexID % 6;
    HorizontalMetalScreenLinePrimitive line = lines[lineIndex];

    float2 start = line.from;
    float2 end = line.to;
    float2 vector = end - start;
    float segmentLength = max(length(vector), 0.001);
    float2 axis = vector / segmentLength;
    float2 normal = float2(-axis.y, axis.x);
    float halfWidth = max(line.width, 0.5) * 0.5;
    float2 cap = axis * halfWidth;

    float2 corners[6] = {
        start - cap + normal * halfWidth,
        end + cap + normal * halfWidth,
        start - cap - normal * halfWidth,
        start - cap - normal * halfWidth,
        end + cap + normal * halfWidth,
        end + cap - normal * halfWidth
    };

    LineVertexOut out;
    float2 screenPosition = corners[cornerIndex];
    out.position = horizon_screen_to_clip(screenPosition, uniforms);
    out.screenPosition = screenPosition;
    out.start = start;
    out.end = end;
    out.color = line.color;
    out.halfWidth = halfWidth;
    out.dashLength = line.dashLength;
    out.dashGap = line.dashGap;
    out.outlineOnly = 0.0;
    return out;
}

fragment float4 horizon_backdrop_fragment(
    BackdropVertexOut in [[stage_in]],
    constant HorizontalMetalBackdropUniforms& uniforms [[buffer(0)]]
) {
    float2 viewportSize = max(uniforms.viewportSize, float2(1.0));
    float2 boundsSize = max(uniforms.boundsMax - uniforms.boundsMin, float2(1.0));
    float2 screen = in.position.xy / max(uniforms.backingScale, 1.0);

    float availableWidth = max(viewportSize.x - uniforms.fitInsets.y - uniforms.fitInsets.w, 1.0);
    float availableHeight = max(viewportSize.y - uniforms.fitInsets.x - uniforms.fitInsets.z, 1.0);
    float fitScale = min(availableWidth / boundsSize.x, availableHeight / boundsSize.y);
    float scale = fitScale * max(uniforms.zoom, 0.01);
    float2 contentSize = boundsSize * scale;
    float2 screenOrigin = (viewportSize - contentSize) * 0.5 + uniforms.pan;

    float2 world;
    world.x = uniforms.boundsMin.x + (screen.x - screenOrigin.x) / scale;
    world.y = uniforms.boundsMax.y - (screen.y - screenOrigin.y) / scale;

    float4 color = uniforms.backgroundColor;
    if (uniforms.showGrid > 0.5 && uniforms.gridSpacing.x > 0.0 && uniforms.gridSpacing.y > 0.0) {
        float nearestX = uniforms.gridOrigin.x + round((world.x - uniforms.gridOrigin.x) / uniforms.gridSpacing.x) * uniforms.gridSpacing.x;
        float nearestY = uniforms.gridOrigin.y + round((world.y - uniforms.gridOrigin.y) / uniforms.gridSpacing.y) * uniforms.gridSpacing.y;
        float dx = abs((world.x - nearestX) * scale);
        float dy = abs((world.y - nearestY) * scale);
        float halfWidth = max(uniforms.gridLineWidth, 0.5) * 0.5;
        float aa = 0.85;

        float vertical = (1.0 - smoothstep(halfWidth, halfWidth + aa, dx))
            * (1.0 - smoothstep(uniforms.markSize, uniforms.markSize + aa, dy));
        float horizontal = (1.0 - smoothstep(halfWidth, halfWidth + aa, dy))
            * (1.0 - smoothstep(uniforms.markSize, uniforms.markSize + aa, dx));
        float gridAlpha = max(vertical, horizontal) * uniforms.gridColor.a;
        color.rgb = mix(color.rgb, uniforms.gridColor.rgb, gridAlpha);
        color.a = max(color.a, gridAlpha);
    }

    return color;
}

fragment float4 horizon_triangle_fragment(TriangleVertexOut in [[stage_in]]) {
    return in.color;
}

fragment float4 horizon_line_fragment(LineVertexOut in [[stage_in]]) {
    float2 segment = in.end - in.start;
    float segmentLengthSquared = max(dot(segment, segment), 0.000001);
    float t = clamp(dot(in.screenPosition - in.start, segment) / segmentLengthSquared, 0.0, 1.0);
    float2 closest = in.start + segment * t;
    float distanceToSegment = length(in.screenPosition - closest);
    float aa = max(fwidth(distanceToSegment), 0.75);
    float coverage = 1.0 - smoothstep(in.halfWidth, in.halfWidth + aa, distanceToSegment);
    if (in.outlineOnly > 0.5 && in.halfWidth > 1.25) {
        float borderWidth = min(max(1.0, aa), in.halfWidth);
        float innerEdge = max(in.halfWidth - borderWidth, 0.0);
        coverage *= smoothstep(innerEdge, innerEdge + aa, distanceToSegment);
    }
    if (in.dashLength > 0.0 && in.dashGap > 0.0) {
        float segmentLength = max(length(segment), 0.001);
        float along = clamp(dot(in.screenPosition - in.start, segment / segmentLength), 0.0, segmentLength);
        float phase = fmod(along, in.dashLength + in.dashGap);
        coverage *= phase <= in.dashLength ? 1.0 : 0.0;
    }
    float4 color = in.color;
    color.a *= coverage;
    return color;
}

fragment float4 horizon_handle_fragment(HandleVertexOut in [[stage_in]]) {
    float metric = in.shape > 0.5
        ? length(in.localPosition)
        : abs(in.localPosition.x) + abs(in.localPosition.y);
    float outerAA = max(fwidth(metric), 0.75);
    float innerAA = max(fwidth(metric), 0.75);
    float outerCoverage = 1.0 - smoothstep(in.outerRadius, in.outerRadius + outerAA, metric);
    float innerCoverage = 1.0 - smoothstep(in.innerRadius, in.innerRadius + innerAA, metric);
    float4 color = mix(in.outerColor, in.innerColor, innerCoverage);
    color.a *= outerCoverage;
    return color;
}

fragment float4 horizon_texture_fragment(
    TextureVertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]],
    constant float& opacity [[buffer(0)]]
) {
    constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
    float4 color = texture.sample(textureSampler, in.texCoord);
    color.rgb *= opacity;
    color.a *= opacity;
    return color;
}
"""
#endif
