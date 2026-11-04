#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A canvas draws all its layers into one Metal view, so they reach the
/// screen on the same frame. They were once a view each, stacked, and the
/// top overlay (the highlight) presented a frame after the base and the
/// board's own layers while zooming.
@MainActor
final class HorizontalMetalCanvasLayersTests: XCTestCase {
    private func settle(until predicate: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func metalViews(in view: NSView) -> [MTKView] {
        (view as? MTKView).map { [$0] } ?? view.subviews.flatMap { metalViews(in: $0) }
    }

    private func line(y: Double, group: Int = 0) -> HorizontalMetalLinePrimitive {
        .init(from: .init(x: 0, y: y), to: .init(x: 2_500_000, y: y),
              color: HorizontalMetalRGBA(Color.yellow), width: 0, minimumWidth: 1,
              compositeGroup: group)
    }

    private func frame() -> HorizontalMetalCanvasFrame {
        HorizontalMetalCanvasFrame(
            bounds: .init(points: [.init(x: -10_000_000, y: -10_000_000), .init(x: 10_000_000, y: 10_000_000)]),
            viewportSize: SIMD2(800, 600))
    }

    func testACanvasDrawsEveryLayerIntoItsOneMetalView() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let bounds = HorizontalRect(points: [.init(x: -10_000_000, y: -10_000_000), .init(x: 10_000_000, y: 10_000_000)])
        let canvas = InteractiveCanvasView(
            bounds: bounds,
            viewport: .constant(CanvasViewport()),
            backgroundColor: .black,
            metalLines: [line(y: 0)],
            metalLineKey: 1,
            metalOverlayLines: [line(y: 1_000_000, group: 4)],
            metalOverlayLineKey: 2,
            metalTopOverlayLines: [line(y: 2_000_000)],
            metalTopOverlayLineKey: 3
        )
        let hosted = NSHostingView(rootView: canvas
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        func renderer() -> HorizontalMetalBackdropView.Renderer? {
            metalViews(in: hosted).first?.delegate as? HorizontalMetalBackdropView.Renderer
        }
        let labels = ["Metal base", "Metal overlay", "Metal top overlay"]
        let drawn = await settle {
            labels.allSatisfy { renderer()?.layer(labeled: $0)?.presentedContentKey != nil }
        }
        XCTAssertTrue(drawn)
        XCTAssertEqual(metalViews(in: hosted).count, 1, "Every layer, the cursor's too, draws into the one view")
        let renderer = try XCTUnwrap(renderer())
        XCTAssertEqual(renderer.layers.map(\.label), labels)
        XCTAssertNotNil(renderer.layer(labeled: "Metal cursor"), "The cursor's layer reaches the view through its channel")
        XCTAssertEqual(renderer.layer(labeled: "Metal base")?.residentLineEndpoints(compositeGroup: 0).map(\.from.y), [0])
        XCTAssertEqual(renderer.layer(labeled: "Metal overlay")?.residentLineEndpoints(compositeGroup: 4).map(\.from.y), [1_000_000])
        XCTAssertEqual(renderer.layer(labeled: "Metal top overlay")?.residentLineEndpoints(compositeGroup: 0).map(\.from.y), [2_000_000])
    }

    /// A layer the canvas has nothing for keeps nothing resident, as an
    /// unmounted view of its own kept nothing, and uploads whole once it has
    /// content again, even under the keys it had before.
    func testALayerWithNoContentDropsItsBuffersAndUploadsWholeOnItsReturn() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let renderer = HorizontalMetalBackdropView.Renderer()
        let base = HorizontalMetalCanvasLayerContent(lines: [line(y: 0)], lineKey: 1, label: "Metal base")
        let top = HorizontalMetalCanvasLayerContent(lines: [line(y: 2_000_000, group: 5)], lineKey: 3, label: "Metal top overlay")
        let bounds = frame().bounds
        func update(_ layers: [HorizontalMetalCanvasLayerContent?]) -> Bool {
            renderer.update(bounds: bounds, viewport: CanvasViewport(), fitInsets: .defaultFit,
                            backingScale: 1, viewportSize: SIMD2(800, 600), layers: layers)
        }

        XCTAssertTrue(update([base, top]))
        let layer = try XCTUnwrap(renderer.layer(labeled: "Metal top overlay"))
        let uploads = layer.residentSceneUploads
        XCTAssertFalse(update([base, top]), "Nothing changed")

        _ = update([base, nil])
        XCTAssertNil(renderer.layer(labeled: "Metal top overlay"))
        XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: 5).count, 0)
        XCTAssertNotNil(renderer.layer(labeled: "Metal base"))

        XCTAssertTrue(update([base, top]), "The returning layer is a new scene under its old keys")
        XCTAssertTrue(renderer.layer(labeled: "Metal top overlay") === layer)
        XCTAssertEqual(layer.residentSceneUploads, uploads + 1)
        XCTAssertEqual(layer.residentLineEndpoints(compositeGroup: 5).map(\.from.y), [2_000_000])
    }

    /// A translucent layer group is drawn to its texture again only when what
    /// it is drawn from changed: a pointer move, or a change in another
    /// layer, composites the texture it already has.
    func testCompositeTexturesAreReusedUntilWhatTheyShowChanges() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let renderer = HorizontalMetalBackdropView.Renderer()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), device: renderer.device)
        view.delegate = renderer
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = renderer.sampleCount
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }

        let bounds = frame().bounds
        var board = HorizontalMetalCanvasLayerContent(layerOpacity: 0.6, lines: [line(y: 0, group: 4)], lineKey: 1,
                                                      label: "Metal overlay")
        let highlight = HorizontalMetalCanvasLayerContent(lines: [line(y: 0)], lineKey: 1, label: "Metal top overlay")
        func update(_ layers: [HorizontalMetalCanvasLayerContent?], zoom: CGFloat = 1) {
            _ = renderer.update(bounds: bounds, viewport: CanvasViewport(zoom: zoom), fitInsets: .defaultFit,
                                backingScale: 1, viewportSize: SIMD2(400, 300), layers: layers)
        }
        update([board, highlight])
        let overlay = try XCTUnwrap(renderer.layer(labeled: "Metal overlay"))
        view.draw()
        XCTAssertEqual(overlay.compositeTextureRenders, 1)
        view.draw()
        let channel = HorizontalMetalCanvasLiveLayer()
        channel.attach(renderer: renderer, view: view)
        channel.submit(HorizontalMetalCanvasLayerContent(screenLines: [], screenLineKey: 7, label: "Metal cursor"))
        view.draw()
        XCTAssertEqual(overlay.compositeTextureRenders, 1, "Redraws with nothing new for the board reuse its textures")

        update([board, HorizontalMetalCanvasLayerContent(lines: [line(y: 5)], lineKey: 2, label: "Metal top overlay")])
        view.draw()
        XCTAssertEqual(overlay.compositeTextureRenders, 1, "A change in another layer leaves this one's textures be")

        renderer.updateLiveViewport(CanvasViewport(zoom: 2))
        view.draw()
        XCTAssertEqual(overlay.compositeTextureRenders, 2, "A zoom draws them again")

        var patches = HorizontalMetalBufferPatches()
        patches.lineTranslationPatches = [.init(compositeGroup: 4, start: 0, count: 1, delta: .init(x: 1_000_000, y: 0), angle: 0)]
        board.bufferPatches = patches
        board.bufferPatchKey = patches.hashValue
        update([board, highlight], zoom: 2)
        view.draw()
        XCTAssertEqual(overlay.compositeTextureRenders, 3, "A move patch draws them again")
        view.draw()
        XCTAssertEqual(overlay.compositeTextureRenders, 3)

        board.lines = [line(y: 3_000_000, group: 4)]
        board.lineKey = 2
        board.bufferPatches = .empty
        update([board, highlight], zoom: 2)
        view.draw()
        XCTAssertEqual(overlay.compositeTextureRenders, 4, "A new scene draws them again")
    }

    /// The cursor's layer comes through `HorizontalMetalCanvasLiveLayer`: what
    /// was submitted before the view attached reaches it on attaching, and a
    /// submit after that goes straight to the renderer.
    func testTheCursorLayerReachesTheRendererThroughItsChannel() throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let renderer = HorizontalMetalBackdropView.Renderer()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 80, height: 60), device: renderer.device)
        let channel = HorizontalMetalCanvasLiveLayer()
        let crosshair = [HorizontalMetalScreenLinePrimitive(from: CGPoint(x: 0, y: 30), to: CGPoint(x: 80, y: 30),
                                                            color: HorizontalMetalRGBA(Color.green), width: 1)]
        let content = HorizontalMetalCanvasLayerContent(screenLines: crosshair, screenLineKey: crosshair.hashValue,
                                                        label: "Metal cursor", marksLoadProfileFirstDraw: false)

        channel.submit(content)
        XCTAssertNil(renderer.layer(labeled: "Metal cursor"))
        channel.attach(renderer: renderer, view: view)
        XCTAssertNotNil(renderer.layer(labeled: "Metal cursor"))
        XCTAssertFalse(renderer.updateLiveLayer(content), "The same content again is nothing new")

        channel.submit(nil)
        XCTAssertNil(renderer.layer(labeled: "Metal cursor"))
        channel.submit(content)
        XCTAssertNotNil(renderer.layer(labeled: "Metal cursor"))
    }
}
#endif
