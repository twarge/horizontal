import CoreGraphics
import Foundation
import Metal
import QuartzCore
import RealityKit

/// When the 3D view draws a frame. Nothing changes on its own in a board's
/// scene, so a still view draws nothing: a frame is drawn when something
/// asks for one (the camera moved, the scene or its options changed, the
/// view was resized), every refresh while an animation plays (the explode
/// slider's), and once more after the last one ends so its final pose is
/// what stays on screen.
struct BoardSceneFrameSchedule: Equatable {
    private(set) var wantsFrame = false
    private var trailingFrames = 0

    mutating func request() {
        wantsFrame = true
    }

    /// At a display refresh: whether to draw now, `animating` saying
    /// whether an animation is playing.
    mutating func shouldDraw(animating: Bool) -> Bool {
        if animating {
            wantsFrame = false
            trailingFrames = 1
            return true
        }
        if wantsFrame {
            wantsFrame = false
            return true
        }
        if trailingFrames > 0 {
            trailingFrames -= 1
            return true
        }
        return false
    }

    /// Nothing to draw until something asks.
    var isIdle: Bool {
        !wantsFrame && trailingFrames == 0
    }
}

/// The 3D view's picture: RealityKit's own renderer drawing the scene into a
/// Metal layer, a frame at a time and only when `BoardSceneFrameSchedule`
/// says so. RealityKit's view (ARView) redrew every display refresh however
/// still the scene was, which kept a third of a core busy with the 3D pane
/// open and nothing happening. The platform views own the display link that
/// calls `step(at:)` and pause it while `isActive` is false; they hand the
/// camera rig their gestures and pick along its rays, as before.
@MainActor
final class BoardSceneRenderSurface {
    /// Where frames go: the layer's drawables on screen, or a texture, which
    /// tests read back.
    enum Target {
        case layer
        case texture(MTLTexture)
    }

    let rig = BoardSceneCameraRig()
    let layer: CAMetalLayer
    private(set) var shownScene: BoardSceneEntities?
    var target: Target = .layer {
        didSet { requestFrame() }
    }
    /// Called when `isActive` may have changed, for the view to pause or
    /// resume its display link.
    var onActivityChange: (() -> Void)?

    private let contentAnchor = AnchorEntity(world: .zero)
    private let renderer: RealityRenderer?
    private let commandQueue: MTLCommandQueue?
    private let renderedEvent: MTLEvent?
    private var renderedValue: UInt64 = 0
    private var schedule = BoardSceneFrameSchedule()
    private var playing = Set<AnimationPlaybackController>()
    private var subscriptions = [EventSubscription]()
    private var missedDrawables = 0
    private var lastStep: CFTimeInterval?
    private var isVisible = true
    private var hasArea = false
    private var reportedRenderError = false

    /// Frames drawn so far, for tests.
    private(set) var drawnFrames = 0
    /// The command buffer that follows the latest frame's rendering, for
    /// tests to wait on.
    private(set) var lastFrameCommands: MTLCommandBuffer?

    /// The longest step simulated time takes between two frames, so an
    /// animation resumed after a pause doesn't jump to its end.
    static let maximumStep: CFTimeInterval = 1.0 / 15
    private static let drawableRetries = 3

    init(layer: CAMetalLayer) {
        self.layer = layer
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        renderedEvent = device?.makeEvent()
        renderer = try? RealityRenderer()
        layer.device = device
        // RealityKit renders in Display P3 and writes sRGB-encoded values.
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.allowsNextDrawableTimeout = true
        layer.needsDisplayOnBoundsChange = false

        rig.onChange = { [weak self] in
            self?.requestFrame()
        }
        guard let renderer else {
            return
        }
        renderer.entities.append(contentAnchor)
        renderer.entities.append(rig.anchor)
        renderer.activeCamera = rig.camera
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.lighting.resource = BoardSceneEnvironment.resource()
        renderer.lighting.intensityExponent = BoardSceneEnvironment.intensityExponent
        // An animation (the explode slider's) is drawn every refresh while
        // it plays. Each one reports its start, and its end once or twice
        // (completed, then terminated); `step` also drops any that stopped
        // without saying.
        subscriptions.append(renderer.subscribe(to: AnimationEvents.PlaybackStarted.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.playing.insert(event.playbackController)
            }
        })
        subscriptions.append(renderer.subscribe(to: AnimationEvents.PlaybackCompleted.self) { [weak self] event in
            MainActor.assumeIsolated {
                _ = self?.playing.remove(event.playbackController)
            }
        })
        subscriptions.append(renderer.subscribe(to: AnimationEvents.PlaybackTerminated.self) { [weak self] event in
            MainActor.assumeIsolated {
                _ = self?.playing.remove(event.playbackController)
            }
        })
    }

    /// The display link should run: a frame is wanted or an animation plays,
    /// and there is somewhere visible to draw it.
    var isActive: Bool {
        (!schedule.isIdle || !playing.isEmpty) && canDraw
    }

    /// Whether an animation is playing, for tests.
    var isAnimating: Bool {
        !playing.isEmpty
    }

    private var canDraw: Bool {
        guard renderer != nil else {
            return false
        }
        switch target {
        case .layer: return isVisible && hasArea
        case .texture: return true
        }
    }

    // MARK: What is drawn

    func show(_ scene: BoardSceneEntities) {
        shownScene?.root.removeFromParent()
        contentAnchor.addChild(scene.root)
        shownScene = scene
        rig.sceneSize = Float(max(scene.boardWidth, scene.boardDepth))
        requestFrame()
    }

    func setBackground(_ color: CGColor) {
        renderer?.cameraSettings.colorBackground = .color(color)
        layer.backgroundColor = color
        requestFrame()
    }

    /// The stops the studio light is turned down by (the scene's
    /// `environmentExposure` while a spot is lit).
    func setEnvironmentExposure(_ stops: Float) {
        let exponent = BoardSceneEnvironment.intensityExponent + stops
        guard let renderer, renderer.lighting.intensityExponent != exponent else {
            return
        }
        renderer.lighting.intensityExponent = exponent
        requestFrame()
    }

    /// The view's size in points and its screen's scale.
    func setSize(_ size: CGSize, scale: CGFloat) {
        let scale = max(scale, 1)
        let drawable = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        hasArea = drawable.width >= 1 && drawable.height >= 1
        if layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        if hasArea, layer.drawableSize != drawable {
            layer.drawableSize = drawable
            requestFrame()
        } else {
            onActivityChange?()
        }
    }

    /// Whether the window shows the view at all: an occluded or minimised
    /// window draws nothing, and draws what it missed when it shows again.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else {
            return
        }
        isVisible = visible
        if visible {
            requestFrame()
        } else {
            onActivityChange?()
        }
    }

    /// Something on screen changed: draw it at the next refresh.
    func requestFrame() {
        schedule.request()
        onActivityChange?()
    }

    // MARK: Drawing

    /// A display refresh at `timestamp`: draws a frame if one is due, and
    /// tells the view when it can stop the display link.
    func step(at timestamp: CFTimeInterval) {
        playing = playing.filter { $0.isValid && $0.isPlaying }
        guard canDraw, schedule.shouldDraw(animating: !playing.isEmpty) else {
            lastStep = nil
            onActivityChange?()
            return
        }
        let deltaTime = lastStep.map { min(max(timestamp - $0, 0), Self.maximumStep) } ?? 0
        lastStep = timestamp
        draw(deltaTime: deltaTime)
        if !isActive {
            lastStep = nil
            onActivityChange?()
        }
    }

    private func draw(deltaTime: TimeInterval) {
        guard let renderer, let commandQueue, let renderedEvent else {
            return
        }
        let texture: MTLTexture
        var drawable: CAMetalDrawable?
        switch target {
        case .layer:
            guard let next = layer.nextDrawable() else {
                // No drawable this refresh (the compositor is behind, or
                // the window is going away): try again at the next, a few
                // times, since each try can wait for one.
                missedDrawables += 1
                if missedDrawables <= Self.drawableRetries {
                    schedule.request()
                }
                return
            }
            missedDrawables = 0
            drawable = next
            texture = next.texture
        case .texture(let offscreen):
            texture = offscreen
        }
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
            renderedValue += 1
            try renderer.updateAndRender(
                deltaTime: deltaTime,
                cameraOutput: output,
                actionsAfterRender: [.signal(renderedEvent, value: renderedValue)]
            )
        } catch {
            if !reportedRenderError {
                reportedRenderError = true
                NSLog("3D view: RealityKit could not render: %@", String(describing: error))
            }
            return
        }
        // Shown once RealityKit's commands are done with the texture.
        guard let commands = commandQueue.makeCommandBuffer() else {
            return
        }
        commands.label = "3D view present"
        commands.encodeWaitForEvent(renderedEvent, value: renderedValue)
        if let drawable {
            commands.present(drawable)
        }
        commands.commit()
        lastFrameCommands = commands
        drawnFrames += 1
    }
}
