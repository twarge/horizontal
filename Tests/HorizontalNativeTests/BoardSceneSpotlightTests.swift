import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import simd
import UniformTypeIdentifiers
import XCTest
@testable import HorizontalNative

/// The 3D view's Spotlight: a highlighted part is lit by a spot over it that
/// lights the part and a small margin of board around it, and nothing past
/// that, under it for a part on the bottom. Rendered offscreen from straight
/// above, on a plain grey board under the scene's own lights, with the beam
/// hidden so only the light is measured. Set HORIZONTAL_SPOTLIGHT_RENDERS to a
/// folder to have the renders written there as PNGs.
@MainActor
final class BoardSceneSpotlightTests: XCTestCase {
    private let partSize = SIMD3<Float>(2, 1, 2)
    private let boardTop: Float = 0.5

    private func scene(bottom: Bool = false) -> BoardSceneEntities {
        let board = HorizontalBoard.poolEditorBoard(uuid: "spot", name: "Spot", url: URL(fileURLWithPath: "/tmp/spot"))
        let asset = BoardSceneModelLibrary.shared.boxAsset(
            size: partSize,
            materials: [BoardSceneMaterialSpec(color: BoardSceneColor(red: 0.2, green: 0.2, blue: 0.2))]
        )
        var description = BoardSceneDescription(board: board, center: .zero, boardThickness: 1.6, boardWidth: 40, boardDepth: 40)
        description.boardBoxMin = SIMD3(-20, -1.1, -20)
        description.boardBoxMax = SIMD3(20, boardTop, 20)
        description.lights = BoardSceneFactory.lights(width: 40, depth: 40)
        // The part stands on the board's top, or hangs from its bottom.
        let y = bottom ? -1.1 - partSize.y / 2 : boardTop + partSize.y / 2
        description.models = [BoardSceneModelPlacement(
            packageID: "a", componentID: "c-a", group: .model, explodeFactor: bottom ? -3 : 3,
            asset: asset, transform: simd_float4x4(translation: SIMD3(0, y, 0))
        )]
        let scene = BoardSceneEntities(description: description)
        scene.applyDisplayOptions(BoardDisplayOptions(), copperColor: .orange, materialColors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil), layerColors: [:])
        let surface = ModelEntity(
            mesh: .generateBox(width: 40, height: 1.6, depth: 40),
            materials: [BoardSceneMaterials.material(BoardSceneMaterialSpec(color: BoardSceneColor(red: 0.45, green: 0.45, blue: 0.45), roughness: 0.8))]
        )
        surface.position = SIMD3(0, boardTop - 0.8, 0)
        scene.root.addChild(surface)
        return scene
    }

    /// Straight down at the board's top (up at its bottom), 16 mm across.
    private func render(_ scene: BoardSceneEntities, fromBelow: Bool = false, name: String) async throws -> CGImage {
        let camera = HorizontalSceneCameraState(
            matrix: BoardSceneCameraMath.lookAt(
                position: SIMD3(0, fromBelow ? -60 : 60, 0),
                target: .zero,
                up: SIMD3(0, 0, fromBelow ? 1 : -1)
            ),
            orthographicScale: 8
        )
        let image = try await BoardSceneOffscreenRenderer.render(
            scene, camera: camera, projection: .orthogonal,
            size: CGSize(width: 640, height: 640),
            background: BoardSceneColor(red: 0, green: 0, blue: 0)
        )
        write(image, name: name)
        return image
    }

    private func write(_ image: CGImage, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["HORIZONTAL_SPOTLIGHT_RENDERS"], !folder.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The brightness, 0 to 765, of the pixels in a row through the middle.
    private func middleRow(_ image: CGImage) -> [Int] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = height / 2
        return (0..<width).map { x in
            let i = (row * width + x) * 4
            return Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])
        }
    }

    /// How much the spot brightens the board at `mm` from the part's middle,
    /// along +x, over the board lit as it is without it. 40 pixels a
    /// millimetre: an orthographic scale of 8 is 8 mm up and down from the
    /// middle of 640 pixels.
    private func gain(lit: [Int], plain: [Int], atMillimetres mm: Float) -> Int {
        let x = lit.count / 2 + Int((mm * 40).rounded())
        return lit[x] - plain[x]
    }

    private func hideBeams(_ scene: BoardSceneEntities) {
        for rig in scene.highlightRigs {
            rig.findEntity(named: "highlight-beam")?.isEnabled = false
        }
    }

    /// The spots off and the house lights left down: the board as the
    /// spot finds it.
    private func putOutTheSpots(_ scene: BoardSceneEntities) {
        for light in scene.highlightLights {
            light.isEnabled = false
        }
    }

    func testTheHouseLightsGoDownWhileASpotIsLit() async throws {
        let scene = scene()
        let full = scene.houseLightIntensities
        XCTAssertEqual(full.count, 4, "the key, fill, rim and under-light")
        XCTAssertEqual(scene.environmentExposure, 0)
        scene.applyHighlight(componentIDs: ["c-a"])
        let level = BoardSceneEntities.spotlitHouseLightLevel
        for (dimmed, up) in zip(scene.houseLightIntensities, full) {
            XCTAssertEqual(dimmed, up * level, accuracy: 0.5)
        }
        XCTAssertEqual(scene.environmentExposure, log2(level), accuracy: 0.001, "the studio light goes down with them")

        let plain = middleRow(try await render(self.scene(), name: "house-up"))
        hideBeams(scene)
        putOutTheSpots(scene)
        let dimmed = middleRow(try await render(scene, name: "house-down"))
        XCTAssertGreaterThan(plain[60] - dimmed[60], 40, "the board away from the part is darker")

        scene.applyHighlight(componentIDs: [])
        XCTAssertEqual(scene.houseLightIntensities, full, "up again when the spot goes")
        XCTAssertEqual(scene.environmentExposure, 0)
    }

    func testPastTheLightBudgetTheHouseLightsStayUp() {
        let budget = BoardSceneEntities.highlightLightBudget
        let scene = scene()
        let full = scene.houseLightIntensities
        // More parts than the budget: the highlight marks them with beams
        // alone, and with no spot lit there is nothing to stand out.
        let board = HorizontalBoard.poolEditorBoard(uuid: "many", name: "Many", url: URL(fileURLWithPath: "/tmp/many"))
        let asset = BoardSceneModelLibrary.shared.boxAsset(size: partSize, materials: [BoardSceneMaterialSpec(color: BoardSceneColor(red: 0.2, green: 0.2, blue: 0.2))])
        var description = BoardSceneDescription(board: board, center: .zero, boardThickness: 1.6, boardWidth: 40, boardDepth: 40)
        description.lights = BoardSceneFactory.lights(width: 40, depth: 40)
        description.models = (0...budget).map { index in
            BoardSceneModelPlacement(packageID: "p\(index)", componentID: "c\(index)", group: .model, explodeFactor: 3,
                                     asset: asset, transform: simd_float4x4(translation: SIMD3(Float(index) * 3 - 15, 1, 0)))
        }
        let many = BoardSceneEntities(description: description)
        many.applyHighlight(componentIDs: Set((0...budget).map { "c\($0)" }))
        XCTAssertTrue(many.highlightLights.isEmpty)
        XCTAssertEqual(many.houseLightIntensities, full)
        XCTAssertEqual(many.environmentExposure, 0)
        many.applyHighlight(componentIDs: Set((0..<budget).map { "c\($0)" }))
        XCTAssertEqual(many.houseLightLevel, BoardSceneEntities.spotlitHouseLightLevel, "back within the budget, the spots light and the house goes down")
    }

    func testTheSpotLightsThePartAndASmallMarginOfBoardAndNoMore() async throws {
        let scene = scene()
        _ = try await render(scene, name: "top-plain")
        scene.applyHighlight(componentIDs: ["c-a"])
        _ = try await render(scene, name: "top-spot")
        // From the side, as the view first shows a board: for the eye only.
        if ProcessInfo.processInfo.environment["HORIZONTAL_SPOTLIGHT_RENDERS"] != nil {
            let side = HorizontalSceneCameraState(
                matrix: BoardSceneCameraMath.lookAt(position: SIMD3(-34, 30, 34), target: SIMD3(0, 8, 0), up: SIMD3(0, 1, 0))
            )
            for (name, shown) in [("perspective-plain", self.scene()), ("perspective-spot", scene)] {
                let image = try await BoardSceneOffscreenRenderer.render(
                    shown, camera: side, projection: .perspective, size: CGSize(width: 800, height: 600),
                    background: BoardSceneColor(red: 0.12, green: 0.12, blue: 0.13)
                )
                write(image, name: name)
            }
        }
        hideBeams(scene)
        let lit = middleRow(try await render(scene, name: "top-spot-no-beam"))
        putOutTheSpots(scene)
        let dark = middleRow(try await render(scene, name: "top-house-down"))

        let low = SIMD3<Float>(-1, boardTop, -1), high = SIMD3<Float>(1, boardTop + 1, 1)
        let geometry = BoardSceneEntities.spotGeometry(low: low, high: high, bottom: false)
        // Just off the part, inside the pool: lit well past the house lights.
        let inside = gain(lit: lit, plain: dark, atMillimetres: 1.2)
        XCTAssertGreaterThan(inside, 60, "the board just past the part is in the spot (pool to \(geometry.poolRadius) mm)")
        // A millimetre past the edge of the falloff: the spot adds nothing.
        let outside = gain(lit: lit, plain: dark, atMillimetres: geometry.edgeRadius + 1)
        XCTAssertLessThan(abs(outside), 8, "past \(geometry.edgeRadius) mm the board is as the house lights leave it")
        // Halfway through the falloff, dimmer than inside and brighter than outside.
        let fading = gain(lit: lit, plain: dark, atMillimetres: (geometry.poolRadius + geometry.edgeRadius) / 2)
        XCTAssertLessThan(fading, inside)
        XCTAssertGreaterThan(fading, outside)
    }

    func testAPartOnTheBottomIsLitFromBelow() async throws {
        let scene = scene(bottom: true)
        _ = try await render(scene, fromBelow: true, name: "bottom-plain")
        scene.applyHighlight(componentIDs: ["c-a"])
        _ = try await render(scene, fromBelow: true, name: "bottom-spot")
        hideBeams(scene)
        let lit = middleRow(try await render(scene, fromBelow: true, name: "bottom-spot-no-beam"))
        let topSide = middleRow(try await render(scene, name: "bottom-spot-seen-from-top"))
        putOutTheSpots(scene)
        let dark = middleRow(try await render(scene, fromBelow: true, name: "bottom-house-down"))
        let topDark = middleRow(try await render(scene, name: "bottom-house-down-seen-from-top"))
        XCTAssertGreaterThan(gain(lit: lit, plain: dark, atMillimetres: 1.2), 60, "the underside of the board by the part is in the spot")
        XCTAssertLessThan(abs(gain(lit: topSide, plain: topDark, atMillimetres: 1.2)), 8, "the board's top is not lit by a spot under it")
    }

    func testTheBeamRunsFromTheLampToThePartsFoot() {
        let scene = scene()
        scene.applyHighlight(componentIDs: ["c-a"])
        let rig = try! XCTUnwrap(scene.highlightRigs.first)
        let beam = try! XCTUnwrap(rig.findEntity(named: "highlight-beam") as? ModelEntity)
        let bounds = beam.visualBounds(relativeTo: nil)
        let light = try! XCTUnwrap(scene.highlightLights.first)
        let lamp = light.position(relativeTo: nil)
        XCTAssertEqual(bounds.max.y, lamp.y, accuracy: 0.01, "the beam's tip is at the lamp")
        // The part's foot, risen with the explode as the part is.
        let foot = rig.parent!.convert(position: SIMD3(0, boardTop, 0), to: nil).y
        XCTAssertEqual(bounds.min.y, foot + 0.08, accuracy: 0.01, "the beam stops just short of the board")
        XCTAssertGreaterThan(lamp.y, foot + partSize.y, "the lamp hangs over the part")
        XCTAssertEqual(lamp.x, bounds.center.x, accuracy: 0.01)
        XCTAssertEqual(lamp.z, bounds.center.z, accuracy: 0.01)
    }
}
