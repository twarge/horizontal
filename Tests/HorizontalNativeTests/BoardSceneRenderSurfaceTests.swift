#if canImport(AppKit)
import AppKit
#endif
import Metal
import QuartzCore
import RealityKit
import simd
import XCTest
@testable import HorizontalNative

/// The 3D view draws only when something changes: a still view draws its
/// first frame and then nothing, the camera, the scene and the view's own
/// settings each ask for one frame, and an animation is drawn every refresh
/// until it ends and once after. The parts' shadows are drawn on the board,
/// the same every frame. Frames are drawn into a texture and read back, the
/// display refreshes stepped by hand.
@MainActor
final class BoardSceneRenderSurfaceTests: XCTestCase {
    private static let refresh: CFTimeInterval = 1.0 / 60

    // MARK: Scene

    /// A grey board 40 mm square with a dark part 4 mm square and 6 mm tall
    /// standing in its middle, under the scene's own lights.
    private func scene(options: BoardDisplayOptions = BoardDisplayOptions()) -> BoardSceneEntities {
        let board = HorizontalBoard.poolEditorBoard(uuid: "surface", name: "Surface", url: URL(fileURLWithPath: "/tmp/surface"))
        let asset = BoardSceneModelLibrary.shared.boxAsset(
            size: SIMD3(4, 6, 4),
            materials: [BoardSceneMaterialSpec(color: BoardSceneColor(red: 0.3, green: 0.3, blue: 0.3))]
        )
        var description = BoardSceneDescription(board: board, center: .zero, boardThickness: 1.6, boardWidth: 40, boardDepth: 40)
        description.boardBoxMin = SIMD3(-20, -1.1, -20)
        description.boardBoxMax = SIMD3(20, 0.5, 20)
        description.lights = BoardSceneFactory.lights(width: 40, depth: 40)
        description.models = [BoardSceneModelPlacement(
            packageID: "a", componentID: "c-a", group: .model, explodeFactor: 3,
            asset: asset, transform: simd_float4x4(translation: SIMD3(0, 3.5, 0))
        )]
        description.meshes = BoardSceneFactory.shadowItems(
            models: description.models, lights: description.lights, center: .zero,
            topY: 0.5 + BoardSceneFactory.shadowStandOff, bottomY: -1.1 - BoardSceneFactory.shadowStandOff
        )
        let scene = BoardSceneEntities(description: description)
        apply(options, to: scene)
        let surface = ModelEntity(
            mesh: .generateBox(width: 40, height: 1.6, depth: 40),
            materials: [BoardSceneMaterials.material(BoardSceneMaterialSpec(color: BoardSceneColor(red: 0.6, green: 0.6, blue: 0.6), roughness: 0.8))]
        )
        surface.position = SIMD3(0, -0.3, 0)
        scene.root.addChild(surface)
        return scene
    }

    private func apply(_ options: BoardDisplayOptions, to scene: BoardSceneEntities) {
        scene.applyDisplayOptions(options, copperColor: .orange, materialColors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil), layerColors: [:])
    }

    /// From straight above, the whole board in view.
    private let topCamera = HorizontalSceneCameraState(
        matrix: BoardSceneCameraMath.lookAt(position: SIMD3(0, 80, 0), target: .zero, up: SIMD3(0, 0, -1)),
        orthographicScale: 20
    )

    private let size = 320

    private func texture() throws -> MTLTexture {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// A surface drawing `scene` into a texture, looking down at it.
    private func surface(showing scene: BoardSceneEntities) throws -> (surface: BoardSceneRenderSurface, texture: MTLTexture) {
        let texture = try texture()
        let surface = BoardSceneRenderSurface(layer: CAMetalLayer())
        surface.target = .texture(texture)
        surface.setBackground(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.2, alpha: 1))
        surface.show(scene)
        surface.rig.apply(.orthogonal, board: scene.board)
        surface.rig.apply(topCamera)
        return (surface, texture)
    }

    private func pixels(_ texture: MTLTexture, after surface: BoardSceneRenderSurface) throws -> [UInt8] {
        let commands = try XCTUnwrap(surface.lastFrameCommands)
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed, "the frame's presenting commands waited for RealityKit's and ran")
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return bytes
    }

    /// Display refreshes from `start` until the surface stops, at most
    /// `limit`: how many there were, and the time after the last.
    @discardableResult
    private func stepUntilIdle(_ surface: BoardSceneRenderSurface, from start: CFTimeInterval, limit: Int = 120) -> (steps: Int, time: CFTimeInterval) {
        var time = start
        var steps = 0
        while surface.isActive, steps < limit {
            surface.step(at: time)
            time += Self.refresh
            steps += 1
        }
        return (steps, time)
    }

    // MARK: Schedule

    func testTheScheduleDrawsOnceForEveryBurstOfRequestsAndThroughAnAnimation() {
        var schedule = BoardSceneFrameSchedule()
        XCTAssertTrue(schedule.isIdle)
        XCTAssertFalse(schedule.shouldDraw(animating: false), "nothing asked: nothing drawn")

        schedule.request()
        schedule.request()
        XCTAssertFalse(schedule.isIdle)
        XCTAssertTrue(schedule.shouldDraw(animating: false))
        XCTAssertFalse(schedule.shouldDraw(animating: false), "two requests before a refresh are one frame")
        XCTAssertTrue(schedule.isIdle)

        XCTAssertTrue(schedule.shouldDraw(animating: true))
        XCTAssertTrue(schedule.shouldDraw(animating: true))
        XCTAssertFalse(schedule.isIdle)
        XCTAssertTrue(schedule.shouldDraw(animating: false), "once more after the animation ends")
        XCTAssertFalse(schedule.shouldDraw(animating: false))
        XCTAssertTrue(schedule.isIdle)
    }

    // MARK: Drawing on demand

    func testAStillViewDrawsItsFirstFrameAndThenNothing() throws {
        let (surface, _) = try surface(showing: scene())
        XCTAssertTrue(surface.isActive, "a scene shown asks for a frame")
        let run = stepUntilIdle(surface, from: 0)
        XCTAssertEqual(surface.drawnFrames, 1)
        XCTAssertEqual(run.steps, 1)
        XCTAssertFalse(surface.isActive, "the display link can stop")
        for index in 0..<30 {
            surface.step(at: run.time + Double(index) * Self.refresh)
        }
        XCTAssertEqual(surface.drawnFrames, 1, "a still scene is not drawn again")
    }

    func testTheCameraTheBackgroundAndTheLightEachAskForAFrame() throws {
        let (surface, _) = try surface(showing: scene())
        var time = stepUntilIdle(surface, from: 0).time

        surface.rig.orbit(dx: 20, dy: 0)
        surface.rig.zoom(magnification: 0.1)
        XCTAssertTrue(surface.isActive)
        time = stepUntilIdle(surface, from: time).time
        XCTAssertEqual(surface.drawnFrames, 2, "two camera moves before a refresh are one frame")

        surface.setBackground(CGColor(srgbRed: 0.2, green: 0.1, blue: 0.1, alpha: 1))
        time = stepUntilIdle(surface, from: time).time
        XCTAssertEqual(surface.drawnFrames, 3)

        surface.setEnvironmentExposure(0)
        XCTAssertFalse(surface.isActive, "the studio light as it was asks for nothing")
        surface.setEnvironmentExposure(log2(0.3))
        stepUntilIdle(surface, from: time)
        XCTAssertEqual(surface.drawnFrames, 4)
    }

    func testAViewWithNoAreaOrInAHiddenWindowWaitsToDraw() {
        let surface = BoardSceneRenderSurface(layer: CAMetalLayer())
        surface.setSize(.zero, scale: 2)
        surface.requestFrame()
        XCTAssertFalse(surface.isActive, "nowhere to draw")
        surface.setSize(CGSize(width: 200, height: 100), scale: 2)
        XCTAssertEqual(surface.layer.drawableSize, CGSize(width: 400, height: 200))
        XCTAssertTrue(surface.isActive, "the frame asked for while it had no area")
        surface.setVisible(false)
        XCTAssertFalse(surface.isActive, "an occluded window draws nothing")
        surface.setVisible(true)
        XCTAssertTrue(surface.isActive, "and draws when it shows again")
    }

    func testAnExplodeIsDrawnEveryRefreshToItsEndAndThenStops() throws {
        let scene = scene()
        let (surface, texture) = try surface(showing: scene)
        var time = stepUntilIdle(surface, from: 0).time
        let before = surface.drawnFrames

        var options = BoardDisplayOptions()
        options.threeDExplode = 4
        apply(options, to: scene)
        surface.requestFrame()
        var sawAnimation = false
        var steps = 0
        while surface.isActive, steps < 120 {
            surface.step(at: time)
            sawAnimation = sawAnimation || surface.isAnimating
            time += Self.refresh
            steps += 1
        }
        XCTAssertTrue(sawAnimation, "the explode's move is an animation the surface follows")
        XCTAssertFalse(surface.isActive, "and stops when it ends")
        let frames = surface.drawnFrames - before
        // 0.15 s at 60 Hz, plus the first frame and the one after.
        XCTAssertGreaterThanOrEqual(frames, 8)
        XCTAssertLessThanOrEqual(frames, 16)

        let container = try XCTUnwrap(scene.root.findEntity(named: "explode:3000"))
        XCTAssertEqual(container.position.y, 12, accuracy: 0.001, "the part's layer ended 3 × 4 mm up")
        let last = try pixels(texture, after: surface)
        surface.requestFrame()
        stepUntilIdle(surface, from: time)
        XCTAssertEqual(try pixels(texture, after: surface), last, "the last frame drawn showed where it ended")
    }

    // MARK: Shadows

    func testAPartsShadowFallsAwayFromTheKeyLightOnTheBoardsFace() throws {
        let lights = BoardSceneFactory.lights(width: 40, depth: 40)
        let key = try XCTUnwrap(lights.first { $0.castsShadow && $0.direction.y < 0 }).direction
        let asset = BoardSceneModelLibrary.shared.boxAsset(size: SIMD3(4, 6, 4), materials: [BoardSceneMaterialSpec(color: BoardSceneColor(red: 0.3, green: 0.3, blue: 0.3))])
        let models = [BoardSceneModelPlacement(
            packageID: "a", componentID: "c-a", group: .model, explodeFactor: 3,
            asset: asset, transform: simd_float4x4(translation: SIMD3(0, 3.5, 0))
        )]
        let items = BoardSceneFactory.shadowItems(models: models, lights: lights, center: .zero, topY: 0.51, bottomY: -1.11)
        XCTAssertEqual(Set(items.map(\.group)), [.shadow, .allModelShadow], "the placed models' set and every model's")
        let shadow = try XCTUnwrap(items.first { $0.group == .shadow })
        XCTAssertEqual(shadow.explodeFactor, 3, "it moves with the models")
        XCTAssertEqual(shadow.drawOrder, .shadow)
        XCTAssertEqual(shadow.mesh.boundsMin.y, 0.51, accuracy: 0.0001, "flat on the board's face")
        XCTAssertEqual(shadow.mesh.boundsMax.y, 0.51, accuracy: 0.0001)
        // The part's top corners, 6.5 mm up, cast along the key onto the face.
        let reach = key * ((0.51 - 6.5) / key.y)
        let penumbra = Float(BoardSceneFactory.shadowPenumbraStep) * Float(BoardSceneFactory.shadowLayerCount - 1)
        for (x, z) in [(-2, -2), (2, -2), (-2, 2), (2, 2)] as [(Float, Float)] {
            for point in [SIMD3<Float>(x, 0.51, z), SIMD3<Float>(x, 0.51, z) + reach] {
                XCTAssertGreaterThanOrEqual(point.x, shadow.mesh.boundsMin.x - 0.01)
                XCTAssertLessThanOrEqual(point.x, shadow.mesh.boundsMax.x + 0.01)
                XCTAssertGreaterThanOrEqual(point.z, shadow.mesh.boundsMin.z - 0.01)
                XCTAssertLessThanOrEqual(point.z, shadow.mesh.boundsMax.z + 0.01)
            }
        }
        let farthest = max(abs(reach.x), abs(reach.z)) + 2 + penumbra
        XCTAssertLessThanOrEqual(max(-shadow.mesh.boundsMin.x, shadow.mesh.boundsMax.x, -shadow.mesh.boundsMin.z, shadow.mesh.boundsMax.z), farthest + 0.01, "and no farther, its soft edge aside")

        // A part on the bottom is shadowed on the bottom face, by the
        // under-light.
        let bottom = [BoardSceneModelPlacement(
            packageID: "b", componentID: "c-b", group: .model, explodeFactor: -3,
            asset: asset, transform: simd_float4x4(translation: SIMD3(0, -4.1, 0))
        )]
        let under = BoardSceneFactory.shadowItems(models: bottom, lights: lights, center: .zero, topY: 0.51, bottomY: -1.11)
        let underside = try XCTUnwrap(under.first { $0.group == .shadow })
        XCTAssertEqual(underside.mesh.boundsMax.y, -1.11, accuracy: 0.0001)
        XCTAssertEqual(underside.explodeFactor, -3)
    }

    func testTheShadowsAreCastAlongTheLightsTheSceneIsLitWith() throws {
        let scene = scene()
        for (index, light) in BoardSceneFactory.lights(width: 40, depth: 40).enumerated() {
            let entity = try XCTUnwrap(scene.root.findEntity(named: "light:\(index)"))
            XCTAssertNil(entity.components[DirectionalLightComponent.Shadow.self], "no RealityKit shadow: it changes from frame to frame")
            // A light shines down its entity's -z: the way the shadow is cast.
            let matrix = entity.transformMatrix(relativeTo: nil)
            let shines = -simd_normalize(SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
            XCTAssertGreaterThan(simd_dot(shines, light.direction), 0.999, "light \(index)")
        }
    }

    func testShadowsShowWithTheOptionForTheModelsShownAndFadeWithTheHouseLights() throws {
        let scene = scene()
        XCTAssertEqual(scene.shadowMeshCount, 2)
        let placed = try XCTUnwrap(scene.root.findEntity(named: "group:shadow"))
        let every = try XCTUnwrap(scene.root.findEntity(named: "group:allModelShadow"))
        XCTAssertTrue(scene.showsShadows, "on by default")
        XCTAssertTrue(placed.isEnabled)
        XCTAssertFalse(every.isEnabled)

        var options = BoardDisplayOptions()
        options.threeDModelMode = .all
        apply(options, to: scene)
        XCTAssertFalse(placed.isEnabled)
        XCTAssertTrue(every.isEnabled, "every model shown: every model's shadow")
        options.threeDModelMode = .none
        apply(options, to: scene)
        XCTAssertFalse(scene.showsShadows, "no models, no shadows")
        options.threeDModelMode = .placed
        options.threeDExplode = 2
        apply(options, to: scene)
        XCTAssertFalse(scene.showsShadows, "exploded, the parts float clear of the board")
        options.threeDExplode = 0
        options.threeDModelMode = .placed
        options.threeDShadows = false
        apply(options, to: scene)
        XCTAssertFalse(scene.showsShadows)

        XCTAssertEqual(scene.shadowLayerOpacity, BoardSceneFactory.shadowLayerOpacity)
        scene.applyHighlight(componentIDs: ["c-a"])
        XCTAssertEqual(scene.shadowLayerOpacity, BoardSceneFactory.shadowLayerOpacity * BoardSceneEntities.spotlitHouseLightLevel, accuracy: 0.0001, "the key they stand for is down")
        scene.applyHighlight(componentIDs: [])
        XCTAssertEqual(scene.shadowLayerOpacity, BoardSceneFactory.shadowLayerOpacity)
    }

    func testThePartCastsAShadowOnTheBoardThatIsTheSameEveryFrame() throws {
        func frames(shadows: Bool) throws -> [[UInt8]] {
            var options = BoardDisplayOptions()
            options.threeDShadows = shadows
            let (surface, texture) = try surface(showing: scene(options: options))
            var time: CFTimeInterval = 0
            var frames = [[UInt8]]()
            for _ in 0..<6 {
                surface.requestFrame()
                time = stepUntilIdle(surface, from: time).time
                frames.append(try pixels(texture, after: surface))
            }
            return frames
        }
        let shaded = try frames(shadows: true)
        let plain = try frames(shadows: false)
        for frame in shaded.dropFirst() {
            XCTAssertTrue(frame == shaded[0], "with nothing moving, every frame is the same")
        }

        func luma(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Double {
            let index = (y * size + x) * 4
            return 0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1]) + 0.0722 * Double(bytes[index + 2])
        }
        // 8 px a millimetre. Darkened: 20 levels or more darker with shadows.
        let millimetre = Double(size) / 40
        var darkened = 0
        var farFromThePart = 0
        for y in 0..<size {
            for x in 0..<size {
                guard luma(plain[0], x, y) - luma(shaded[0], x, y) >= 20 else {
                    continue
                }
                darkened += 1
                let dx = (Double(x) - Double(size) / 2) / millimetre
                let dy = (Double(y) - Double(size) / 2) / millimetre
                if hypot(dx, dy) > 14 {
                    farFromThePart += 1
                }
            }
        }
        // The part's shadow: 4 mm wide and about 4 mm long, some 16 of the
        // board's 1,600 mm².
        XCTAssertGreaterThan(darkened, size * size / 250, "the part shades the board beside it")
        XCTAssertLessThan(farFromThePart, darkened / 50, "and nothing far from it")

        // Away from the part the board is as it was without shadows.
        func mean(_ bytes: [UInt8], x: Int, y: Int) -> Double {
            var total = 0.0
            for py in y..<(y + 24) {
                for px in x..<(x + 24) {
                    total += luma(bytes, px, py)
                }
            }
            return total / (24 * 24)
        }
        for (x, y) in [(16, 16), (size - 40, 16), (16, size - 40), (size - 40, size - 40)] {
            let lit = mean(shaded[0], x: x, y: y)
            let unlit = mean(plain[0], x: x, y: y)
            XCTAssertEqual(lit, unlit, accuracy: 0.5, "the board's corner at \(x), \(y)")
        }
    }

    #if canImport(AppKit)
    // MARK: The Mac's view

    func testTheMacViewStopsItsDisplayLinkOnceTheSceneIsDrawn() throws {
        _ = NSApplication.shared
        let view = BoardSceneRenderView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        view.show(scene())
        func settle(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        settle(0.3)
        if !window.occlusionState.contains(.visible) {
            // Behind the other windows on screen, as a test's window
            // usually is: nothing is drawn until it shows.
            XCTAssertEqual(view.surface.drawnFrames, 0, "an occluded window draws nothing")
            XCTAssertFalse(view.isDrawing)
            view.surface.setVisible(true)
        }
        settle(0.5)
        XCTAssertGreaterThanOrEqual(view.surface.drawnFrames, 1, "the scene was drawn")
        XCTAssertFalse(view.isDrawing, "and the display link is paused")
        let drawn = view.surface.drawnFrames
        settle(0.5)
        XCTAssertEqual(view.surface.drawnFrames, drawn, "nothing drawn while nothing changes")

        view.rig.orbit(dx: 30, dy: 0)
        XCTAssertTrue(view.isDrawing, "a camera move starts it")
        settle(0.3)
        XCTAssertGreaterThan(view.surface.drawnFrames, drawn)
        XCTAssertFalse(view.isDrawing)
    }
    #endif
}
