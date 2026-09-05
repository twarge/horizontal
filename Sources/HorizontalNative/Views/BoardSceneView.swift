#if canImport(AppKit)
import AppKit
import HorizontalStepImporter
#elseif canImport(UIKit)
import UIKit
#endif
import HorizontalPlaneClipper
import SceneKit
import SwiftUI

#if canImport(AppKit)
private typealias HorizontalSceneScalar = CGFloat
#else
private typealias HorizontalSceneScalar = Float
#endif

private func horizonSceneScalar(_ value: Double) -> HorizontalSceneScalar {
    HorizontalSceneScalar(value)
}

private func horizonSceneScalar(_ value: Float) -> HorizontalSceneScalar {
    HorizontalSceneScalar(value)
}

private func horizonScenePlatformColor(_ color: Color) -> HorizontalPlatformColor {
    #if canImport(AppKit)
    return NSColor(color).usingColorSpace(.sRGB) ?? HorizontalDefaultTheme.backgroundNS
    #else
    return UIColor(color)
    #endif
}

#if canImport(AppKit)
private func horizonScenePlatformColor(_ color: Color, resolvingAgainst appearance: NSAppearance) -> HorizontalPlatformColor {
    var resolvedColor = HorizontalDefaultTheme.backgroundNS
    appearance.performAsCurrentDrawingAppearance {
        let nsColor = NSColor(color)
        resolvedColor = nsColor.usingColorSpace(NSColorSpace.sRGB) ?? nsColor
    }
    return resolvedColor
}
#endif

private func horizonSceneConfigureCopperMaterial(_ material: SCNMaterial, color: HorizontalPlatformColor) {
    material.diffuse.contents = color
    material.emission.contents = HorizontalPlatformColor.clear
    material.specular.contents = HorizontalPlatformColor.white.withAlphaComponent(0.7)
    material.metalness.contents = 0.95
    material.roughness.contents = 0.22
    material.transparency = 1
    material.lightingModel = .physicallyBased
    material.isDoubleSided = true
}

private func horizonSceneConfigurePasteMaterial(_ material: SCNMaterial, color: HorizontalPlatformColor) {
    material.diffuse.contents = color
    material.emission.contents = HorizontalPlatformColor.clear
    material.specular.contents = HorizontalPlatformColor.white.withAlphaComponent(0.82)
    material.metalness.contents = 0.88
    material.roughness.contents = 0.16
    material.transparency = 1
    material.lightingModel = .physicallyBased
    material.isDoubleSided = true
}

private func horizonSceneEffectiveBackgroundColor(
    _ backgroundColor: Color,
    displayOptions: BoardDisplayOptions
) -> Color {
    displayOptions.threeDBackground ? backgroundColor : .horizonPlatformWindowBackground
}

func horizonSceneDefaultOrthographicScale(for board: HorizontalBoard) -> Double {
    let bodyBounds = board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds
    let width = max(bodyBounds.width / 1_000_000.0, 10)
    let depth = max(bodyBounds.height / 1_000_000.0, 10)
    return max(width, depth) * 1.6
}

private func horizonSceneApplyProjection(
    _ projection: HorizontalBoardSceneProjection,
    to cameraNode: SCNNode,
    board: HorizontalBoard
) {
    guard let camera = cameraNode.camera else {
        return
    }

    let usesOrthographicProjection = projection == .orthogonal
    let wasUsingOrthographicProjection = camera.usesOrthographicProjection
    camera.usesOrthographicProjection = usesOrthographicProjection
    if usesOrthographicProjection && !wasUsingOrthographicProjection {
        camera.orthographicScale = horizonSceneDefaultOrthographicScale(for: board)
    }
}

enum HorizontalBoard3DViewPreset: String, CaseIterable, Identifiable {
    case defaultPerspective
    case top
    case bottom
    case frontLeft
    case side
    case backRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultPerspective: "Default Perspective"
        case .top: "Top"
        case .bottom: "Bottom"
        case .side: "Left"
        case .frontLeft: "Front"
        case .backRight: "Right"
        }
    }

    var systemImage: String {
        switch self {
        case .defaultPerspective: "cube"
        case .top: "arrow.down"
        case .bottom: "arrow.up"
        case .side: "arrow.right"
        case .frontLeft: "arrow.up.right"
        case .backRight: "arrow.left"
        }
    }

    var projection: HorizontalBoardSceneProjection {
        self == .defaultPerspective ? .perspective : .orthogonal
    }
}

func horizonSceneCameraState(
    for preset: HorizontalBoard3DViewPreset,
    board: HorizontalBoard
) -> HorizontalSceneCameraState {
    let dimensions = horizonSceneBoardDimensions(for: board)
    let maxDimension = max(dimensions.width, dimensions.depth)
    let distance = max(maxDimension * 2.4, 18)
    let cameraNode = SCNNode()
    let target = SCNVector3(0, 0, 0)
    let position: SCNVector3
    let up: SCNVector3

    switch preset {
    case .defaultPerspective:
        let axisDistance = horizonSceneScalar(distance / sqrt(3.0))
        position = SCNVector3(-axisDistance, axisDistance, axisDistance)
        up = SCNVector3(0, 1, 0)
    case .top:
        position = SCNVector3(0, horizonSceneScalar(distance), 0)
        up = SCNVector3(0, 0, -1)
    case .bottom:
        position = SCNVector3(0, -horizonSceneScalar(distance), 0)
        up = SCNVector3(0, 0, 1)
    case .side:
        position = SCNVector3(-horizonSceneScalar(distance), 0, 0)
        up = SCNVector3(0, 1, 0)
    case .frontLeft:
        position = SCNVector3(0, 0, horizonSceneScalar(distance))
        up = SCNVector3(0, 1, 0)
    case .backRight:
        position = SCNVector3(horizonSceneScalar(distance), 0, 0)
        up = SCNVector3(0, 1, 0)
    }

    cameraNode.position = position
    cameraNode.look(at: target, up: up, localFront: SCNVector3(0, 0, -1))
    let orthographicScale = preset.projection == .orthogonal
        ? horizonSceneDefaultOrthographicScale(for: board)
        : nil
    return HorizontalSceneCameraState(transform: cameraNode.transform, orthographicScale: orthographicScale)
}

private func horizonSceneBoardDimensions(for board: HorizontalBoard) -> (width: Double, depth: Double) {
    let bodyBounds = board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds
    let width = max(bodyBounds.width / 1_000_000.0, 10)
    let depth = max(bodyBounds.height / 1_000_000.0, 10)
    return (width, depth)
}

struct BoardSceneView: View {
    var board: HorizontalBoard
    var displayOptions: BoardDisplayOptions
    var backgroundColor: Color
    var copperColor: Color = Color(red: 0.72, green: 0.45, blue: 0.2)
    var layerColors: [Int: HorizontalRGBColor] = [:]
    var materialColors = HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil)
    var ignoresSceneMouseEvents = false
    var silkscreenClipping: HorizontalSilkscreenClipping? = nil
    @Binding var cameraState: HorizontalSceneCameraState?

    var body: some View {
        // The scene is built lazily inside the host view's coordinator and
        // cached on `(board.url, board.uuid, render display options)`. We must not
        // call `BoardSceneFactory.scene(...)` from `body` — `body` re-runs
        // every time the parent's `@State threeDCameraState` updates (which
        // happens on every pan/zoom event), and rebuilding the SCNScene per
        // gesture is what made the 3D view sluggish.
        //
        // Likewise, no `.id(displayOptions)` here: a layer toggle should swap
        // the scene in place, not destroy and recreate the underlying NSView.
        BoardSceneHostView(
            board: board,
            displayOptions: displayOptions,
            backgroundColor: backgroundColor,
            copperColor: copperColor,
            layerColors: layerColors,
            materialColors: materialColors,
            ignoresSceneMouseEvents: ignoresSceneMouseEvents,
            silkscreenClipping: silkscreenClipping,
            cameraState: $cameraState
        )
        .background(horizonSceneEffectiveBackgroundColor(backgroundColor, displayOptions: displayOptions))
    }
}

/// Caches a `BoardSceneNodes` by board identity so the host view can be
/// re-evaluated freely without paying the cost of a full SCNScene rebuild.
/// Display options, colors, and explode are applied as in-place scene
/// mutations — only a new board triggers a scene rebuild.
private final class BoardSceneSceneCache {
    private var key: BoardSceneCacheKey?
    private var nodes: BoardSceneNodes?

    func nodes(for board: HorizontalBoard, silkscreenClipping: HorizontalSilkscreenClipping? = nil) -> BoardSceneNodes {
        let candidate = BoardSceneCacheKey(board: board, silkscreenClipping: silkscreenClipping)
        if let nodes, candidate == key {
            return nodes
        }
        let built = BoardSceneFactory.buildScene(for: board, silkscreenClipping: silkscreenClipping)
        self.key = candidate
        self.nodes = built
        return built
    }
}

private struct BoardSceneCacheKey: Hashable {
    var boardURL: URL
    var boardUUID: String
    var boardName: String
    var stackupLayers: [HorizontalBoardStackupLayer]
    var userLayers: [HorizontalBoardUserLayer]
    var silkscreenClipping: HorizontalSilkscreenClipping?

    init(board: HorizontalBoard, silkscreenClipping: HorizontalSilkscreenClipping? = nil) {
        self.silkscreenClipping = silkscreenClipping
        self.boardURL = board.url
        self.boardUUID = board.uuid
        self.boardName = board.name
        self.stackupLayers = board.stackupLayers
        self.userLayers = board.userLayers
    }
}

private struct BoardSceneColorKey: Hashable {
    var red: Int
    var green: Int
    var blue: Int
    var alpha: Int

    #if canImport(AppKit)
    init(_ color: Color, appearance: NSAppearance? = nil) {
        var nsColor = HorizontalDefaultTheme.backgroundNS
        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            }
        } else {
            nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        self.init(nsColor)
    }

    private init(_ color: NSColor) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        self.red = Self.quantize(resolved.redComponent)
        self.green = Self.quantize(resolved.greenComponent)
        self.blue = Self.quantize(resolved.blueComponent)
        self.alpha = Self.quantize(resolved.alphaComponent)
    }
    #else
    init(_ color: Color) {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.red = Self.quantize(red)
        self.green = Self.quantize(green)
        self.blue = Self.quantize(blue)
        self.alpha = Self.quantize(alpha)
    }
    #endif

    private static func quantize(_ component: CGFloat) -> Int {
        Int((Double(component) * 10_000).rounded())
    }
}

/// Which surfaces the 3D scene shows: the 3D view's own toggles, never the
/// 2D layer eyes. The package editor hides mask and paste in 2D and the
/// board editor can hide the outline; the 3D view still shows the board.
struct BoardSceneSurfaceVisibility: Equatable {
    var substrate: Bool
    var solderMask: Bool
    var silkscreen: Bool
    var paste: Bool

    init(_ options: BoardDisplayOptions) {
        substrate = options.threeDBoardBody
        solderMask = options.threeDSolderMask
        silkscreen = options.threeDSilkscreen
        paste = options.threeDPaste
    }
}

private struct BoardSceneDisplayOptionsKey: Hashable {
    var boardBody: Bool
    var solderMask: Bool
    var silkscreen: Bool
    var paste: Bool
    var vias: Bool
    var holes: Bool
    var text: Bool
    var packages: Bool
    var decals: Bool
    var keepouts: Bool
    var connectionLines: Bool
    var origin: Bool
    var orientationAxes: Bool
    var outline: Bool
    var panelLabels: Bool
    var projection: HorizontalBoardSceneProjection
    var explode: Double
    var background: Bool
    var solderMaskTransparency: Double
    var viaPlatingMicrons: Double
    var copperMode: HorizontalBoardSceneCopperMode
    var modelMode: HorizontalBoardSceneModelMode

    init(_ options: BoardDisplayOptions) {
        // The 3D view's own surface toggles, not the 2D layer eyes.
        self.boardBody = options.threeDBoardBody
        self.solderMask = options.threeDSolderMask
        self.silkscreen = options.threeDSilkscreen
        self.paste = options.threeDPaste
        self.vias = options.vias
        self.holes = options.holes
        self.text = options.text
        self.packages = options.packages
        self.decals = options.decals
        self.keepouts = options.keepouts
        self.connectionLines = options.connectionLines
        self.origin = options.origin
        self.orientationAxes = options.orientationAxes
        self.outline = options.outline
        self.panelLabels = options.panelLabels
        self.projection = options.threeDProjection
        self.explode = options.threeDExplode
        self.background = options.threeDBackground
        self.solderMaskTransparency = options.threeDSolderMaskTransparency
        self.viaPlatingMicrons = options.threeDViaPlatingMicrons
        self.copperMode = options.threeDCopperMode
        self.modelMode = options.threeDModelMode
    }
}

private struct BoardSceneAppliedOptionsKey: Hashable {
    var sceneKey: BoardSceneCacheKey
    var displayOptions: BoardSceneDisplayOptionsKey
    var backgroundColor: BoardSceneColorKey
    var copperColor: BoardSceneColorKey
    var layerColors: [Int: HorizontalRGBColor]
    var materialColors: HorizontalBoardColors

    #if canImport(AppKit)
    init(
        board: HorizontalBoard,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil,
        displayOptions: BoardDisplayOptions,
        backgroundColor: Color,
        copperColor: Color,
        layerColors: [Int: HorizontalRGBColor],
        materialColors: HorizontalBoardColors,
        appearance: NSAppearance
    ) {
        self.sceneKey = BoardSceneCacheKey(board: board, silkscreenClipping: silkscreenClipping)
        self.displayOptions = BoardSceneDisplayOptionsKey(displayOptions)
        self.backgroundColor = BoardSceneColorKey(backgroundColor, appearance: appearance)
        self.copperColor = BoardSceneColorKey(copperColor, appearance: appearance)
        self.layerColors = layerColors
        self.materialColors = materialColors
    }
    #else
    init(
        board: HorizontalBoard,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil,
        displayOptions: BoardDisplayOptions,
        backgroundColor: Color,
        copperColor: Color,
        layerColors: [Int: HorizontalRGBColor],
        materialColors: HorizontalBoardColors
    ) {
        self.sceneKey = BoardSceneCacheKey(board: board, silkscreenClipping: silkscreenClipping)
        self.displayOptions = BoardSceneDisplayOptionsKey(displayOptions)
        self.backgroundColor = BoardSceneColorKey(backgroundColor)
        self.copperColor = BoardSceneColorKey(copperColor)
        self.layerColors = layerColors
        self.materialColors = materialColors
    }
    #endif
}

/// Holds the SceneKit scene plus categorised node groups and trackable
/// materials so that display-option changes can be applied as fast in-place
/// mutations instead of full scene rebuilds.
private final class BoardSceneNodes {
    let scene: SCNScene
    let cameraNode: SCNNode
    let board: HorizontalBoard
    let boardThickness: Double
    let boardWidth: Double
    let boardDepth: Double

    let substrateGroup = SCNNode()
    let solderMaskGroup = SCNNode()
    let silkscreenGroup = SCNNode()
    let pasteGroup = SCNNode()
    let copperGroup = SCNNode()
    let planeGroup = SCNNode()
    let viaGroup = SCNNode()
    let holeGroup = SCNNode()
    let modelGroup = SCNNode()
    let noPopulateModelGroup = SCNNode()
    let placeholderModelGroup = SCNNode()
    let textGroup = SCNNode()
    let packageArtGroup = SCNNode()
    let decalGroup = SCNNode()
    let keepoutGroup = SCNNode()
    let connectionGroup = SCNNode()
    let originGroup = SCNNode()
    let orientationAxesGroup = SCNNode()
    let outlineGroup = SCNNode()
    let panelLabelGroup = SCNNode()

    var center: HorizontalPoint = .zero
    var vias: [HorizontalMarker] = []

    var substrateFaceMaterials: [SCNMaterial] = []
    var substrateSideMaterials: [SCNMaterial] = []

    struct ExplodableEntry {
        let node: SCNNode
        let layer: Int?
        let baseY: Double
        let explodeFactor: Double
    }
    var explodableNodes: [ExplodableEntry] = []

    init(scene: SCNScene, cameraNode: SCNNode, board: HorizontalBoard, boardThickness: Double, boardWidth: Double, boardDepth: Double) {
        self.scene = scene
        self.cameraNode = cameraNode
        self.board = board
        self.boardThickness = boardThickness
        self.boardWidth = boardWidth
        self.boardDepth = boardDepth

        let groups: [SCNNode] = [
            substrateGroup, solderMaskGroup, silkscreenGroup, pasteGroup,
            copperGroup, planeGroup, viaGroup, holeGroup, modelGroup, noPopulateModelGroup, placeholderModelGroup, textGroup,
            packageArtGroup, decalGroup, keepoutGroup, connectionGroup,
            originGroup, orientationAxesGroup, outlineGroup, panelLabelGroup,
        ]
        for group in groups {
            scene.rootNode.addChildNode(group)
        }
    }

    func addExplodable(node: SCNNode, layer: Int?, baseY: Double, explodeFactor: Double? = nil) {
        let factor = explodeFactor ?? BoardSceneFactory.explodeFactor(
            for: layer, board: board, boardThickness: boardThickness
        )
        explodableNodes.append(.init(node: node, layer: layer, baseY: baseY, explodeFactor: factor))
    }

    func applyDisplayOptions(
        _ options: BoardDisplayOptions,
        backgroundColor: Color,
        copperColor: Color,
        materialColors: HorizontalBoardColors,
        layerColors: [Int: HorizontalRGBColor],
        board: HorizontalBoard
    ) {
        let surfaces = BoardSceneSurfaceVisibility(options)
        substrateGroup.isHidden = !surfaces.substrate
        solderMaskGroup.isHidden = !surfaces.solderMask
        silkscreenGroup.isHidden = !surfaces.silkscreen
        pasteGroup.isHidden = !surfaces.paste
        copperGroup.isHidden = options.threeDCopperMode == .off
        // Planes are copper: in 3D they follow the copper mode, the same as
        // every other copper group.
        planeGroup.isHidden = options.threeDCopperMode == .off
        viaGroup.isHidden = !options.vias || options.threeDCopperMode == .off
        holeGroup.isHidden = !options.holes
        modelGroup.isHidden = options.threeDModelMode == .none
        noPopulateModelGroup.isHidden = options.threeDModelMode != .all
        placeholderModelGroup.isHidden = options.threeDModelMode != .all
        textGroup.isHidden = !options.text
        packageArtGroup.isHidden = !options.packages
        decalGroup.isHidden = !options.decals
        keepoutGroup.isHidden = !options.keepouts
        connectionGroup.isHidden = !options.connectionLines
        originGroup.isHidden = !options.origin
        orientationAxesGroup.isHidden = !options.orientationAxes
        outlineGroup.isHidden = !options.outline
        panelLabelGroup.isHidden = !options.panelLabels

        let substrateColor = materialColors.substrate?.nsColor
            ?? HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.outline)
        for mat in substrateFaceMaterials {
            mat.diffuse.contents = substrateColor
            mat.transparency = 1
        }
        for mat in substrateSideMaterials {
            mat.diffuse.contents = substrateColor
            mat.transparency = 1
        }

        let solderMaskColor = materialColors.solderMask?.nsColor
            ?? HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.topMask)
        updateSolderMaskMaterials(
            in: solderMaskGroup,
            color: solderMaskColor,
            transparency: options.threeDSolderMaskTransparency
        )

        let silkscreenColor = materialColors.silkscreen?.nsColor
            ?? HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.topSilkscreen)
        updateMaterials(in: silkscreenGroup, color: silkscreenColor)

        if options.threeDCopperMode == .layerColor {
            updateCopperMaterials(in: copperGroup, layerColors: layerColors)
            updateCopperMaterials(in: planeGroup, layerColors: layerColors)
        } else {
            let nsCopper = horizonScenePlatformColor(copperColor)
            updateAllCopperMaterials(in: copperGroup, color: nsCopper)
            updateAllCopperMaterials(in: planeGroup, color: nsCopper)
        }

        let layerSeparation = max(0, min(options.threeDExplode, 12))
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15
        for entry in explodableNodes {
            let offset = entry.explodeFactor * layerSeparation
            entry.node.position.y = horizonSceneScalar(entry.baseY + offset)
        }
        SCNTransaction.commit()

        rebuildVias(
            layerSeparation: layerSeparation,
            color: horizonScenePlatformColor(copperColor),
            platingMicrons: options.threeDViaPlatingMicrons
        )

        let bgColor = horizonSceneEffectiveBackgroundColor(
            backgroundColor, displayOptions: options
        )
        scene.background.contents = horizonScenePlatformColor(bgColor)

        horizonSceneApplyProjection(options.threeDProjection, to: cameraNode, board: board)

    }

    private func rebuildVias(
        layerSeparation: Double,
        color: HorizontalPlatformColor,
        platingMicrons: Double
    ) {
        viaGroup.enumerateChildNodes { node, _ in node.removeFromParentNode() }

        let platingThickness = max(0, min(platingMicrons, 250)) / 1_000
        let padThickness = 0.04

        for via in vias {
            let outerRadius = max((via.size / BoardSceneFactory.unitsPerMillimeter) / 2, 0.18)
            let drillDiameter = max((via.holeSize ?? via.size * 0.5) / BoardSceneFactory.unitsPerMillimeter, 0.05)
            let holeRadius = max(drillDiameter / 2, 0.04)
            let barrelOuterRadius = holeRadius
            let barrelInnerRadius = max(
                barrelOuterRadius - platingThickness,
                0.001
            )

            let copperLayers = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
            let topLayer = copperLayers.max() ?? HorizontalBoardLayers.topCopper
            let bottomLayer = copperLayers.min() ?? HorizontalBoardLayers.bottomCopper
            let viaSpan = BoardSceneFactory.viaZSpan(for: via, board: board, boardThickness: boardThickness)
            let topY = viaSpan.top
            let bottomY = viaSpan.bottom

            let topExplodeOffset = BoardSceneFactory.explodeFactor(
                for: topLayer, board: board, boardThickness: boardThickness
            ) * layerSeparation
            let bottomExplodeOffset = BoardSceneFactory.explodeFactor(
                for: bottomLayer, board: board, boardThickness: boardThickness
            ) * layerSeparation

            let explodedTop = topY + topExplodeOffset + platingThickness
            let explodedBottom = bottomY + bottomExplodeOffset - platingThickness
            let centerY = (explodedTop + explodedBottom) / 2
            let height = max(explodedTop - explodedBottom, 0.18)

            if let barrelNode = platedBarrelNode(
                outerRadius: barrelOuterRadius,
                innerRadius: barrelInnerRadius,
                height: height,
                color: color
            ) {
                barrelNode.position = BoardSceneFactory.scenePosition(via.position, center: center, y: centerY)
                viaGroup.addChildNode(barrelNode)
            }

            let layersToMark = copperLayers.isEmpty
                ? [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
                : copperLayers
            for layer in layersToMark {
                let layerY = BoardSceneFactory.copperHeight(for: layer, board: board, boardThickness: boardThickness)
                let explodeOffset = BoardSceneFactory.explodeFactor(
                    for: layer, board: board, boardThickness: boardThickness
                ) * layerSeparation
                let copperThickness = BoardSceneFactory.copperThickness(
                    for: layer,
                    board: board,
                    fallback: padThickness
                )
                let isTopCopperRing = layer == HorizontalBoardLayers.topCopper
                let isBottomCopperRing = layer == HorizontalBoardLayers.bottomCopper
                let ringExtraThickness = (isTopCopperRing || isBottomCopperRing) ? platingThickness : 0
                let ringCenterOffset = isTopCopperRing
                    ? ringExtraThickness / 2
                    : (isBottomCopperRing ? -ringExtraThickness / 2 : 0)

                if outerRadius > holeRadius + 0.001,
                   let padNode = annularPadNode(
                    outerRadius: outerRadius, innerRadius: holeRadius,
                    thickness: copperThickness + ringExtraThickness,
                    color: color
                ) {
                    padNode.position = BoardSceneFactory.scenePosition(
                        via.position, center: center, y: layerY + explodeOffset + ringCenterOffset
                    )
                    viaGroup.addChildNode(padNode)
                }
            }
        }
    }

    private func platedBarrelNode(
        outerRadius: Double,
        innerRadius: Double,
        height: Double,
        color: HorizontalPlatformColor
    ) -> SCNNode? {
        guard outerRadius > innerRadius,
              height > 0 else {
            return nil
        }

        let tube = SCNTube(
            innerRadius: CGFloat(innerRadius),
            outerRadius: CGFloat(outerRadius),
            height: CGFloat(height)
        )
        tube.radialSegmentCount = 48
        tube.heightSegmentCount = 1

        let material = SCNMaterial()
        horizonSceneConfigureCopperMaterial(material, color: color)
        tube.materials = [material]

        return SCNNode(geometry: tube)
    }

    private func annularRingPath(outerRadius: Double, innerRadius: Double) -> HorizontalPlatformBezierPath {
        let cgOuter = CGFloat(outerRadius)
        let cgInner = CGFloat(innerRadius)
        #if os(macOS)
        let path = HorizontalPlatformBezierPath()
        path.appendOval(in: CGRect(x: -cgOuter, y: -cgOuter, width: cgOuter * 2, height: cgOuter * 2))
        let hole = HorizontalPlatformBezierPath()
        hole.appendOval(in: CGRect(x: -cgInner, y: -cgInner, width: cgInner * 2, height: cgInner * 2))
        #else
        let path = HorizontalPlatformBezierPath(ovalIn: CGRect(x: -cgOuter, y: -cgOuter, width: cgOuter * 2, height: cgOuter * 2))
        let hole = HorizontalPlatformBezierPath(ovalIn: CGRect(x: -cgInner, y: -cgInner, width: cgInner * 2, height: cgInner * 2))
        #endif
        #if os(macOS)
        path.append(hole.reversed)
        path.flatness = 0.01
        #else
        path.append(hole.reversing())
        path.flatness = 0.01
        #endif
        return path
    }

    private func annularPadNode(
        outerRadius: Double, innerRadius: Double,
        thickness: Double, color: HorizontalPlatformColor
    ) -> SCNNode? {
        let path = annularRingPath(outerRadius: outerRadius, innerRadius: innerRadius)
        let shape = SCNShape(path: path, extrusionDepth: CGFloat(thickness))
        let material = SCNMaterial()
        horizonSceneConfigureCopperMaterial(material, color: color)
        shape.materials = [material]

        let node = SCNNode(geometry: shape)
        node.eulerAngles.x = -.pi / 2
        return node
    }

    private func updateMaterials(in group: SCNNode, color: HorizontalPlatformColor) {
        group.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.diffuse.contents = color
                material.emission.contents = color.withAlphaComponent(0.16)
            }
        }
    }

    private func updateSolderMaskMaterials(
        in group: SCNNode,
        color: HorizontalPlatformColor,
        transparency: Double
    ) {
        let opacity = max(0, min(1, 1 - transparency))
        group.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.diffuse.contents = color
                material.emission.contents = color.withAlphaComponent(0.08)
                material.roughness.contents = 0.62
                material.transparency = opacity
                material.isDoubleSided = true
            }
        }
    }

    private func updateCopperMaterials(in group: SCNNode, layerColors: [Int: HorizontalRGBColor]) {
        group.enumerateChildNodes { node, _ in
            guard let layerStr = node.name,
                  layerStr.hasPrefix("layer:"),
                  let layer = Int(layerStr.dropFirst(6)),
                  HorizontalBoardLayers.isCopper(layer),
                  let color = layerColors[layer],
                  let geometry = node.geometry else { return }
            let nsColor = color.nsColor
            for material in geometry.materials {
                horizonSceneConfigureCopperMaterial(material, color: nsColor)
            }
        }
    }

    private func updateAllCopperMaterials(in group: SCNNode, color: HorizontalPlatformColor) {
        group.enumerateChildNodes { node, _ in
            guard let layerStr = node.name,
                  layerStr.hasPrefix("layer:"),
                  let layer = Int(layerStr.dropFirst(6)),
                  HorizontalBoardLayers.isCopper(layer),
                  let geometry = node.geometry else { return }
            for material in geometry.materials {
                horizonSceneConfigureCopperMaterial(material, color: color)
            }
        }
    }
}

#if canImport(AppKit)
private struct BoardSceneHostView: NSViewRepresentable {
    var board: HorizontalBoard
    var displayOptions: BoardDisplayOptions
    var backgroundColor: Color
    var copperColor: Color
    var layerColors: [Int: HorizontalRGBColor]
    var materialColors: HorizontalBoardColors
    var ignoresSceneMouseEvents: Bool
    var silkscreenClipping: HorizontalSilkscreenClipping? = nil
    @Binding var cameraState: HorizontalSceneCameraState?

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraState: $cameraState)
    }

    func makeNSView(context: Context) -> PannableSceneView {
        let nodes = context.coordinator.sceneCache.nodes(for: board, silkscreenClipping: silkscreenClipping)
        let appliedOptionsKey = BoardSceneAppliedOptionsKey(
            board: board,
            silkscreenClipping: silkscreenClipping,
            displayOptions: displayOptions,
            backgroundColor: backgroundColor,
            copperColor: copperColor,
            layerColors: layerColors,
            materialColors: materialColors,
            appearance: NSApp.effectiveAppearance
        )
        nodes.applyDisplayOptions(
            displayOptions,
            backgroundColor: backgroundColor,
            copperColor: copperColor,
            materialColors: materialColors,
            layerColors: layerColors,
            board: board
        )
        let view = PannableSceneView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.scene = nodes.scene
        context.coordinator.lastAppliedProjection = displayOptions.threeDProjection
        view.pointOfView = nodes.cameraNode
        view.panningCameraNode = nodes.cameraNode
        view.defaultCameraController.pointOfView = nodes.cameraNode
        view.ignoresSceneMouseEvents = ignoresSceneMouseEvents
        view.onCameraStateChange = context.coordinator.updateCameraState
        view.applyBackground(backgroundColor, displayOptions: displayOptions)
        view.applyCameraState(cameraState)
        view.applyProjection(displayOptions.threeDProjection, board: board)
        context.coordinator.lastAppliedOptionsKey = appliedOptionsKey
        return view
    }

    func updateNSView(_ nsView: PannableSceneView, context: Context) {
        context.coordinator.cameraState = $cameraState
        nsView.ignoresSceneMouseEvents = ignoresSceneMouseEvents
        let nodes = context.coordinator.sceneCache.nodes(for: board, silkscreenClipping: silkscreenClipping)
        let sceneSwapped = nsView.scene !== nodes.scene
        let appliedOptionsKey = BoardSceneAppliedOptionsKey(
            board: board,
            silkscreenClipping: silkscreenClipping,
            displayOptions: displayOptions,
            backgroundColor: backgroundColor,
            copperColor: copperColor,
            layerColors: layerColors,
            materialColors: materialColors,
            appearance: nsView.effectiveAppearance
        )
        let optionsChanged = context.coordinator.lastAppliedOptionsKey != appliedOptionsKey
        if sceneSwapped || optionsChanged {
            nodes.applyDisplayOptions(
                displayOptions,
                backgroundColor: backgroundColor,
                copperColor: copperColor,
                materialColors: materialColors,
                layerColors: layerColors,
                board: board
            )
            nsView.applyBackground(backgroundColor, displayOptions: displayOptions)
            context.coordinator.lastAppliedOptionsKey = appliedOptionsKey
        }

        if sceneSwapped {
            nsView.scene = nodes.scene
            nsView.pointOfView = nodes.cameraNode
            nsView.panningCameraNode = nodes.cameraNode
            nsView.defaultCameraController.pointOfView = nodes.cameraNode
        } else {
            if nsView.pointOfView == nil {
                nsView.pointOfView = nodes.cameraNode
            }
        }
        let projectionChanged = context.coordinator.lastAppliedProjection != displayOptions.threeDProjection
        context.coordinator.lastAppliedProjection = displayOptions.threeDProjection
        nsView.onCameraStateChange = context.coordinator.updateCameraState
        if sceneSwapped || projectionChanged || cameraState != context.coordinator.lastReportedState {
            nsView.applyCameraState(cameraState)
            context.coordinator.lastReportedState = cameraState
        }
        if sceneSwapped || projectionChanged {
            nsView.applyProjection(displayOptions.threeDProjection, board: board)
        }
    }

    final class Coordinator {
        var cameraState: Binding<HorizontalSceneCameraState?>
        let sceneCache = BoardSceneSceneCache()
        var lastReportedState: HorizontalSceneCameraState?
        var lastAppliedProjection: HorizontalBoardSceneProjection?
        var lastAppliedOptionsKey: BoardSceneAppliedOptionsKey?

        init(cameraState: Binding<HorizontalSceneCameraState?>) {
            self.cameraState = cameraState
        }

        func updateCameraState(_ state: HorizontalSceneCameraState?) {
            guard cameraState.wrappedValue != state else {
                return
            }

            lastReportedState = state
            cameraState.wrappedValue = state
        }
    }

    final class PannableSceneView: SCNView {
        weak var panningCameraNode: SCNNode?
        var ignoresSceneMouseEvents = false
        var onCameraStateChange: ((HorizontalSceneCameraState?) -> Void)?

        private var requestedBackgroundColor: Color = HorizontalDefaultTheme.background
        private var requestedDisplayOptions = BoardDisplayOptions()
        private var monitor: Any?
        // Coalesces high-frequency camera-state reports (one per scroll/zoom
        // tick) into a single binding write after the gesture settles. Without
        // this, every wheel tick pushed the binding, which cascaded into a full
        // SwiftUI update through `ProjectDocumentView` — making pan/zoom feel
        // sluggish even though the scene itself was static.
        private var pendingReportTimer: Timer?
        private static let reportSettleInterval: TimeInterval = 0.12

        private var activeCameraNode: SCNNode? {
            defaultCameraController.pointOfView ?? pointOfView ?? panningCameraNode
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            ignoresSceneMouseEvents ? nil : super.hitTest(point)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyBackground(requestedBackgroundColor, displayOptions: requestedDisplayOptions)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyBackground(requestedBackgroundColor, displayOptions: requestedDisplayOptions)
            configureMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                removeMonitor()
            }
        }

        private func configureMonitor() {
            removeMonitor()
            guard window != nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self else {
                    return event
                }
                return self.handle(event)
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard !ignoresSceneMouseEvents else {
                return event
            }
            guard let window, event.window === window else {
                return event
            }

            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else {
                return event
            }

            if event.type == .magnify {
                let magnification = event.magnification
                guard magnification != 0 else {
                    return nil
                }

                zoomCamera(magnification: magnification)
                return nil
            }

            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            guard deltaX != 0 || deltaY != 0 else {
                return nil
            }

            if event.hasPreciseScrollingDeltas {
                panCamera(deltaX: deltaX, deltaY: deltaY)
            } else {
                zoomCamera(magnification: deltaY * 0.01)
            }
            return nil
        }

        override func scrollWheel(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            guard let unhandledEvent = handle(event) else {
                return
            }

            super.scrollWheel(with: unhandledEvent)
        }

        override func magnify(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            guard handle(event) != nil else {
                return
            }

            super.magnify(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.mouseDown(with: event)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.rightMouseDown(with: event)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.otherMouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.mouseDragged(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.rightMouseDragged(with: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.otherMouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.mouseUp(with: event)
            reportCameraState()
        }

        override func rightMouseUp(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.rightMouseUp(with: event)
            reportCameraState()
        }

        override func otherMouseUp(with event: NSEvent) {
            guard !ignoresSceneMouseEvents else {
                return
            }
            super.otherMouseUp(with: event)
            reportCameraState()
        }

        func applyCameraState(_ state: HorizontalSceneCameraState?) {
            guard let state,
                  state.isValid,
                  let transform = state.sceneKitTransform,
                  let cameraNode = activeCameraNode else {
                return
            }

            cameraNode.transform = transform
            if cameraNode.camera?.usesOrthographicProjection == true,
               let orthographicScale = state.orthographicScale {
                cameraNode.camera?.orthographicScale = orthographicScale
            }
        }

        func applyProjection(_ projection: HorizontalBoardSceneProjection, board: HorizontalBoard) {
            for cameraNode in [panningCameraNode, pointOfView, defaultCameraController.pointOfView].compactMap({ $0 }) {
                horizonSceneApplyProjection(projection, to: cameraNode, board: board)
            }
            needsDisplay = true
        }

        func applyBackground(_ backgroundColor: Color, displayOptions: BoardDisplayOptions) {
            requestedBackgroundColor = backgroundColor
            requestedDisplayOptions = displayOptions
            let effectiveColor = horizonSceneEffectiveBackgroundColor(
                backgroundColor, displayOptions: displayOptions
            )
            let platformBackgroundColor = horizonScenePlatformColor(
                effectiveColor, resolvingAgainst: effectiveAppearance
            )
            self.backgroundColor = platformBackgroundColor
            scene?.background.contents = platformBackgroundColor

            wantsLayer = true
            layer?.backgroundColor = platformBackgroundColor.cgColor
            layer?.isOpaque = true
        }

        private func panCamera(deltaX: CGFloat, deltaY: CGFloat) {
            guard let cameraNode = activeCameraNode else {
                return
            }

            let transform = cameraNode.presentation.worldTransform
            let rightX = transform.m11
            let rightY = transform.m12
            let rightZ = transform.m13
            let upX = transform.m21
            let upY = transform.m22
            let upZ = transform.m23
            let position = cameraNode.position
            let distance: CGFloat
            if let camera = cameraNode.camera, camera.usesOrthographicProjection {
                distance = max(CGFloat(camera.orthographicScale), 1)
            } else {
                let squaredDistance = position.x * position.x
                    + position.y * position.y
                    + position.z * position.z
                distance = max(sqrt(squaredDistance), 1)
            }
            let scale = distance * 0.0015
            let x = -deltaX * scale
            let y = deltaY * scale
            let moveX = rightX * x + upX * y
            let moveY = rightY * x + upY * y
            let moveZ = rightZ * x + upZ * y

            cameraNode.position = SCNVector3(
                position.x + moveX,
                position.y + moveY,
                position.z + moveZ
            )
            scheduleCameraStateReport()
        }

        private func zoomCamera(magnification: CGFloat) {
            guard magnification != 0, let cameraNode = activeCameraNode else {
                return
            }

            if let camera = cameraNode.camera, camera.usesOrthographicProjection {
                let newScale = min(max(camera.orthographicScale * exp(-Double(magnification)), 1), 5_000)
                guard abs(newScale - camera.orthographicScale) > 0.0001 else {
                    return
                }

                camera.orthographicScale = newScale
                scheduleCameraStateReport()
                return
            }

            let transform = cameraNode.presentation.worldTransform
            let forwardX = -transform.m31
            let forwardY = -transform.m32
            let forwardZ = -transform.m33
            let position = cameraNode.position
            let squaredDistance = position.x * position.x
                + position.y * position.y
                + position.z * position.z
            let distance = max(sqrt(squaredDistance), 1)
            let zoom = distance * magnification * 0.9
            let newPosition = SCNVector3(
                position.x + forwardX * zoom,
                position.y + forwardY * zoom,
                position.z + forwardZ * zoom
            )
            let newSquaredDistance = newPosition.x * newPosition.x
                + newPosition.y * newPosition.y
                + newPosition.z * newPosition.z
            let newDistance = sqrt(newSquaredDistance)
            guard newDistance >= 2, newDistance <= 5_000 else {
                return
            }

            cameraNode.position = newPosition
            scheduleCameraStateReport()
        }

        private func reportCameraState() {
            pendingReportTimer?.invalidate()
            pendingReportTimer = nil

            guard let cameraNode = activeCameraNode else {
                onCameraStateChange?(nil)
                return
            }

            let orthographicScale = cameraNode.camera?.usesOrthographicProjection == true
                ? cameraNode.camera?.orthographicScale
                : nil
            onCameraStateChange?(HorizontalSceneCameraState(transform: cameraNode.transform, orthographicScale: orthographicScale))
        }

        /// Restarts a single-shot timer that will push the latest camera
        /// transform up through the binding once the user stops scrolling /
        /// pinching. Called for every gesture tick; only the final tick's
        /// transform is reported, eliminating per-tick SwiftUI rebuilds.
        private func scheduleCameraStateReport() {
            pendingReportTimer?.invalidate()
            // Timer callbacks fire on the runloop they were scheduled on. We
            // schedule from the main runloop, so the closure runs on the main
            // thread — but Swift 6's strict concurrency can't see that, so we
            // hop explicitly through MainActor before touching `self`.
            pendingReportTimer = Timer.scheduledTimer(
                withTimeInterval: Self.reportSettleInterval,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.reportCameraState()
                }
            }
        }
    }
}
#else
private struct BoardSceneHostView: UIViewRepresentable {
    var board: HorizontalBoard
    var displayOptions: BoardDisplayOptions
    var backgroundColor: Color
    var copperColor: Color
    var layerColors: [Int: HorizontalRGBColor]
    var materialColors: HorizontalBoardColors
    var ignoresSceneMouseEvents: Bool
    var silkscreenClipping: HorizontalSilkscreenClipping? = nil
    @Binding var cameraState: HorizontalSceneCameraState?

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraState: $cameraState)
    }

    func makeUIView(context: Context) -> TouchSceneView {
        let view = TouchSceneView()
        let nodes = context.coordinator.sceneCache.nodes(for: board, silkscreenClipping: silkscreenClipping)
        nodes.applyDisplayOptions(
            displayOptions,
            backgroundColor: backgroundColor,
            copperColor: copperColor,
            materialColors: materialColors,
            layerColors: layerColors,
            board: board
        )
        let platformBackgroundColor = horizonScenePlatformColor(
            horizonSceneEffectiveBackgroundColor(backgroundColor, displayOptions: displayOptions)
        )
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = platformBackgroundColor
        view.antialiasingMode = .multisampling4X
        view.scene = nodes.scene
        context.coordinator.lastAppliedProjection = displayOptions.threeDProjection
        view.pointOfView = nodes.cameraNode
        view.isUserInteractionEnabled = !ignoresSceneMouseEvents
        view.onCameraStateChange = context.coordinator.updateCameraState
        view.applyCameraState(cameraState)
        return view
    }

    func updateUIView(_ uiView: TouchSceneView, context: Context) {
        context.coordinator.cameraState = $cameraState
        uiView.isUserInteractionEnabled = !ignoresSceneMouseEvents
        let nodes = context.coordinator.sceneCache.nodes(for: board, silkscreenClipping: silkscreenClipping)
        let sceneSwapped = uiView.scene !== nodes.scene
        nodes.applyDisplayOptions(
            displayOptions,
            backgroundColor: backgroundColor,
            copperColor: copperColor,
            materialColors: materialColors,
            layerColors: layerColors,
            board: board
        )
        if sceneSwapped {
            uiView.scene = nodes.scene
        }
        let platformBackgroundColor = horizonScenePlatformColor(
            horizonSceneEffectiveBackgroundColor(backgroundColor, displayOptions: displayOptions)
        )
        uiView.backgroundColor = platformBackgroundColor
        let cameraSwapped = uiView.pointOfView !== nodes.cameraNode
        if cameraSwapped {
            uiView.pointOfView = nodes.cameraNode
        }
        let projectionChanged = context.coordinator.lastAppliedProjection != displayOptions.threeDProjection
        context.coordinator.lastAppliedProjection = displayOptions.threeDProjection
        uiView.onCameraStateChange = context.coordinator.updateCameraState
        if sceneSwapped || cameraSwapped || projectionChanged || cameraState != context.coordinator.lastReportedState {
            uiView.applyCameraState(cameraState)
            context.coordinator.lastReportedState = cameraState
        }
    }

    final class Coordinator {
        var cameraState: Binding<HorizontalSceneCameraState?>
        let sceneCache = BoardSceneSceneCache()
        var lastReportedState: HorizontalSceneCameraState?
        var lastAppliedProjection: HorizontalBoardSceneProjection?

        init(cameraState: Binding<HorizontalSceneCameraState?>) {
            self.cameraState = cameraState
        }

        func updateCameraState(_ state: HorizontalSceneCameraState?) {
            guard cameraState.wrappedValue != state else {
                return
            }

            lastReportedState = state
            cameraState.wrappedValue = state
        }
    }

    final class TouchSceneView: SCNView {
        var onCameraStateChange: ((HorizontalSceneCameraState?) -> Void)?

        func applyCameraState(_ state: HorizontalSceneCameraState?) {
            guard let state,
                  state.isValid,
                  let transform = state.sceneKitTransform,
                  let pointOfView else {
                return
            }

            pointOfView.transform = transform
            if pointOfView.camera?.usesOrthographicProjection == true,
               let orthographicScale = state.orthographicScale {
                pointOfView.camera?.orthographicScale = orthographicScale
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            reportCameraState()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            reportCameraState()
        }

        private func reportCameraState() {
            guard let pointOfView else {
                onCameraStateChange?(nil)
                return
            }

            let orthographicScale = pointOfView.camera?.usesOrthographicProjection == true
                ? pointOfView.camera?.orthographicScale
                : nil
            onCameraStateChange?(HorizontalSceneCameraState(transform: pointOfView.transform, orthographicScale: orthographicScale))
        }
    }
}
#endif

private final class BoardSceneClipperPathStorage {
    private let pointBuffers: [UnsafeMutablePointer<HorizontalClipperPoint>]
    private let pathBuffer: UnsafeMutablePointer<HorizontalClipperPath>?
    let count: Int

    var pointer: UnsafePointer<HorizontalClipperPath>? {
        UnsafePointer(pathBuffer)
    }

    init(_ paths: [[HorizontalPoint]]) {
        let validPaths = paths.map { BoardSceneClipperPathStorage.cleaned($0) }.filter { $0.count >= 3 }
        count = validPaths.count
        pathBuffer = count > 0 ? UnsafeMutablePointer<HorizontalClipperPath>.allocate(capacity: count) : nil

        var buffers = [UnsafeMutablePointer<HorizontalClipperPoint>]()
        buffers.reserveCapacity(count)
        for (pathIndex, path) in validPaths.enumerated() {
            let pointBuffer = UnsafeMutablePointer<HorizontalClipperPoint>.allocate(capacity: path.count)
            for (pointIndex, point) in path.enumerated() {
                pointBuffer[pointIndex] = HorizontalClipperPoint(x: point.x, y: point.y)
            }
            buffers.append(pointBuffer)
            pathBuffer?[pathIndex] = HorizontalClipperPath(points: pointBuffer, count: Int32(path.count))
        }
        pointBuffers = buffers
    }

    deinit {
        for buffer in pointBuffers {
            buffer.deallocate()
        }
        pathBuffer?.deallocate()
    }

    static func withPaths<Result>(
        _ subjects: [[HorizontalPoint]],
        _ cutouts: [[HorizontalPoint]],
        _ body: (BoardSceneClipperPathStorage, BoardSceneClipperPathStorage) -> Result
    ) -> Result {
        let subjectStorage = BoardSceneClipperPathStorage(subjects)
        let cutoutStorage = BoardSceneClipperPathStorage(cutouts)
        return body(subjectStorage, cutoutStorage)
    }

    private static func cleaned(_ points: [HorizontalPoint]) -> [HorizontalPoint] {
        var cleaned = [HorizontalPoint]()
        cleaned.reserveCapacity(points.count)
        for point in points where point.x.isFinite && point.y.isFinite {
            if cleaned.last != point {
                cleaned.append(point)
            }
        }
        if cleaned.count > 1 && cleaned.first == cleaned.last {
            cleaned.removeLast()
        }
        return cleaned
    }
}

private extension HorizontalSceneCameraState {
    init(transform: SCNMatrix4, orthographicScale: Double? = nil) {
        self.init(transform: [
            Float(transform.m11), Float(transform.m12), Float(transform.m13), Float(transform.m14),
            Float(transform.m21), Float(transform.m22), Float(transform.m23), Float(transform.m24),
            Float(transform.m31), Float(transform.m32), Float(transform.m33), Float(transform.m34),
            Float(transform.m41), Float(transform.m42), Float(transform.m43), Float(transform.m44),
        ], orthographicScale: orthographicScale)
    }

    var sceneKitTransform: SCNMatrix4? {
        guard isValid else {
            return nil
        }

        return SCNMatrix4(
            m11: horizonSceneScalar(transform[0]),
            m12: horizonSceneScalar(transform[1]),
            m13: horizonSceneScalar(transform[2]),
            m14: horizonSceneScalar(transform[3]),
            m21: horizonSceneScalar(transform[4]),
            m22: horizonSceneScalar(transform[5]),
            m23: horizonSceneScalar(transform[6]),
            m24: horizonSceneScalar(transform[7]),
            m31: horizonSceneScalar(transform[8]),
            m32: horizonSceneScalar(transform[9]),
            m33: horizonSceneScalar(transform[10]),
            m34: horizonSceneScalar(transform[11]),
            m41: horizonSceneScalar(transform[12]),
            m42: horizonSceneScalar(transform[13]),
            m43: horizonSceneScalar(transform[14]),
            m44: horizonSceneScalar(transform[15])
        )
    }
}

private struct HorizontalStepModelBounds {
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var minZ = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    var maxZ = -Double.greatestFiniteMagnitude
    var pointCount = 0

    var isValid: Bool {
        pointCount > 0
    }

    var width: Double {
        maxX - minX
    }

    var depth: Double {
        maxY - minY
    }

    var height: Double {
        maxZ - minZ
    }

    var centerX: Double {
        (minX + maxX) / 2
    }

    var centerY: Double {
        (minY + maxY) / 2
    }

    var centerZ: Double {
        (minZ + maxZ) / 2
    }

    mutating func include(x: Double, y: Double, z: Double) {
        minX = min(minX, x)
        minY = min(minY, y)
        minZ = min(minZ, z)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
        maxZ = max(maxZ, z)
        pointCount += 1
    }
}

private struct HorizontalStepModelColorKey: Hashable, Comparable {
    var red: Int
    var green: Int
    var blue: Int

    static func < (lhs: HorizontalStepModelColorKey, rhs: HorizontalStepModelColorKey) -> Bool {
        if lhs.red != rhs.red {
            return lhs.red < rhs.red
        }
        if lhs.green != rhs.green {
            return lhs.green < rhs.green
        }
        return lhs.blue < rhs.blue
    }

    var nsColor: HorizontalPlatformColor {
        HorizontalPlatformColor(
            red: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: 1
        )
    }
}

private final class HorizontalPackage3DNodeCache: @unchecked Sendable {
    static let shared = HorizontalPackage3DNodeCache()

    private let nativeSceneExtensions: Set<String> = [
        "abc",
        "dae",
        "obj",
        "scn",
        "stl",
        "usd",
        "usda",
        "usdc",
        "usdz"
    ]
    private let stepExtensions: Set<String> = ["step", "stp"]
    private var sceneNodesByURL = [URL: SCNNode]()
    private var failedSceneURLs = Set<URL>()
    /// STEP models already meshed this session, cloned per placement.
    private var stepNodesByURL = [URL: SCNNode]()
    private var stepBoundsByURL = [URL: HorizontalStepModelBounds]()
    private var failedStepURLs = Set<URL>()
    private lazy var cartesianPointExpression: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"CARTESIAN_POINT\s*\(\s*'[^']*'\s*,\s*\(\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*,\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*,\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*\)\s*\)"#,
            options: [.caseInsensitive]
        )
    }()

    private init() {}

    func node(for model: HorizontalPackage3DModel, fallbackColor: HorizontalPlatformColor) -> SCNNode? {
        let fileURL = model.fileURL.standardizedFileURL
        let fileExtension = fileURL.pathExtension.lowercased()

        if let node = nativeSceneNode(for: fileURL, fileExtension: fileExtension, fallbackColor: fallbackColor) {
            return node
        }

        if stepExtensions.contains(fileExtension) {
            #if canImport(AppKit)
            if let cached = stepNodesByURL[fileURL] {
                return cached.clone()
            }
            if let node = stepMeshNode(for: fileURL) {
                stepNodesByURL[fileURL] = node
                return node.clone()
            }
            return stepBoundingNode(for: fileURL, fallbackColor: fallbackColor)
            #else
            return stepBoundingNode(for: fileURL, fallbackColor: fallbackColor)
            #endif
        }

        return nil
    }

    private func nativeSceneNode(
        for fileURL: URL,
        fileExtension: String,
        fallbackColor: HorizontalPlatformColor
    ) -> SCNNode? {
        guard nativeSceneExtensions.contains(fileExtension) else {
            return nil
        }
        if let cached = sceneNodesByURL[fileURL] {
            return cached.clone()
        }
        guard !failedSceneURLs.contains(fileURL) else {
            return nil
        }

        let loadedScene = try? SCNScene(url: fileURL, options: nil)
        guard let loadedScene,
              !loadedScene.rootNode.childNodes.isEmpty else {
            failedSceneURLs.insert(fileURL)
            return nil
        }

        let sourceNode = SCNNode()
        sourceNode.name = fileURL.lastPathComponent
        for child in loadedScene.rootNode.childNodes {
            sourceNode.addChildNode(child.clone())
        }

        let axisNode = SCNNode()
        axisNode.eulerAngles.x = -.pi / 2
        axisNode.addChildNode(sourceNode)
        applyFallbackMaterial(to: axisNode, fallbackColor: fallbackColor)
        sceneNodesByURL[fileURL] = axisNode
        return axisNode.clone()
    }

    #if canImport(AppKit)
    /// The model's mesh: from the on-disk cache when it has one, else
    /// imported (and cached for the next launch).
    private func stepMesh(for fileURL: URL) -> HorizontalStepMeshData? {
        if let cached = HorizontalStepMeshDiskCache.shared.mesh(for: fileURL) {
            return cached
        }
        var mesh = HNStepMesh(vertices: nil, vertexCount: 0, indices: nil, indexCount: 0)
        guard HNStepImport(fileURL.path, &mesh) else {
            return nil
        }
        defer {
            HNStepMeshFree(&mesh)
        }
        let vertexCount = Int(mesh.vertexCount)
        let indexCount = Int(mesh.indexCount)
        guard let meshVertices = mesh.vertices,
              let meshIndices = mesh.indices,
              vertexCount > 0,
              indexCount >= 3,
              indexCount.isMultiple(of: 3) else {
            return nil
        }
        let data = HorizontalStepMeshData(
            vertices: Array(UnsafeBufferPointer(start: meshVertices, count: vertexCount)),
            indices: Array(UnsafeBufferPointer(start: meshIndices, count: indexCount))
        )
        HorizontalStepMeshDiskCache.shared.store(data, for: fileURL)
        return data
    }

    private func stepMeshNode(for fileURL: URL) -> SCNNode? {
        guard let mesh = stepMesh(for: fileURL) else {
            return nil
        }
        let inputVertices = mesh.vertices
        let inputIndices = mesh.indices
        let indexCount = inputIndices.count
        let vertices = inputVertices.map { vertex in
            SCNVector3(vertex.x, vertex.z, -vertex.y)
        }
        let normals = inputVertices.map { vertex in
            SCNVector3(vertex.nx, vertex.nz, -vertex.ny)
        }
        var indicesByColor = [HorizontalStepModelColorKey: [UInt32]]()

        for triangleStart in stride(from: 0, to: indexCount, by: 3) {
            let firstIndex = Int(inputIndices[triangleStart])
            guard firstIndex >= 0 && firstIndex < inputVertices.count else {
                continue
            }

            let key = colorKey(for: inputVertices[firstIndex])
            indicesByColor[key, default: []].append(inputIndices[triangleStart])
            indicesByColor[key, default: []].append(inputIndices[triangleStart + 1])
            indicesByColor[key, default: []].append(inputIndices[triangleStart + 2])
        }

        guard !indicesByColor.isEmpty else {
            return nil
        }

        let sortedKeys = indicesByColor.keys.sorted()
        let elements = sortedKeys.compactMap { key -> SCNGeometryElement? in
            guard let indices = indicesByColor[key],
                  !indices.isEmpty else {
                return nil
            }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
        }
        guard !elements.isEmpty else {
            return nil
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals)
            ],
            elements: elements
        )
        geometry.materials = sortedKeys.map { key in
            let material = SCNMaterial()
            material.diffuse.contents = key.nsColor
            material.roughness.contents = 0.78
            material.metalness.contents = 0.02
            return material
        }

        let node = SCNNode(geometry: geometry)
        node.name = fileURL.lastPathComponent
        return node
    }

    private func colorKey(for vertex: HNStepVertex) -> HorizontalStepModelColorKey {
        HorizontalStepModelColorKey(
            red: clampedColorComponent(vertex.r),
            green: clampedColorComponent(vertex.g),
            blue: clampedColorComponent(vertex.b)
        )
    }

    private func clampedColorComponent(_ value: Float) -> Int {
        max(0, min(255, Int((value * 255).rounded())))
    }
    #endif

    private func stepBoundingNode(for fileURL: URL, fallbackColor: HorizontalPlatformColor) -> SCNNode? {
        guard let bounds = stepBounds(for: fileURL) else {
            return nil
        }

        let width = max(bounds.width, 0.05)
        let height = max(bounds.height, 0.05)
        let depth = max(bounds.depth, 0.05)
        let chamfer = min(max(min(width, depth) * 0.04, 0.015), 0.12)
        let solidGeometry = SCNBox(width: width, height: height, length: depth, chamferRadius: chamfer)
        let solidMaterial = SCNMaterial()
        solidMaterial.diffuse.contents = fallbackColor
        solidMaterial.emission.contents = fallbackColor.withAlphaComponent(0.06)
        solidMaterial.roughness.contents = 0.82
        solidMaterial.transparency = 0.58
        solidGeometry.firstMaterial = solidMaterial

        let solidNode = SCNNode(geometry: solidGeometry)
        solidNode.position = SCNVector3(
            horizonSceneScalar(bounds.centerX),
            horizonSceneScalar(bounds.centerZ),
            horizonSceneScalar(-bounds.centerY)
        )

        let wireGeometry = SCNBox(width: width, height: height, length: depth, chamferRadius: chamfer)
        let wireMaterial = SCNMaterial()
        wireMaterial.diffuse.contents = HorizontalPlatformColor.white.withAlphaComponent(0.22)
        wireMaterial.emission.contents = fallbackColor.withAlphaComponent(0.12)
        wireMaterial.fillMode = .lines
        wireGeometry.firstMaterial = wireMaterial
        let wireNode = SCNNode(geometry: wireGeometry)
        wireNode.position = solidNode.position

        let parent = SCNNode()
        parent.name = fileURL.lastPathComponent
        parent.addChildNode(solidNode)
        parent.addChildNode(wireNode)
        return parent
    }

    private func stepBounds(for fileURL: URL) -> HorizontalStepModelBounds? {
        if let bounds = stepBoundsByURL[fileURL] {
            return bounds
        }
        guard !failedStepURLs.contains(fileURL),
              let expression = cartesianPointExpression,
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            failedStepURLs.insert(fileURL)
            return nil
        }

        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        var bounds = HorizontalStepModelBounds()
        expression.enumerateMatches(in: contents, options: [], range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 4,
                  let xRange = Range(match.range(at: 1), in: contents),
                  let yRange = Range(match.range(at: 2), in: contents),
                  let zRange = Range(match.range(at: 3), in: contents),
                  let x = Double(contents[xRange]),
                  let y = Double(contents[yRange]),
                  let z = Double(contents[zRange]) else {
                return
            }

            bounds.include(x: x, y: y, z: z)
        }

        guard bounds.isValid else {
            failedStepURLs.insert(fileURL)
            return nil
        }

        stepBoundsByURL[fileURL] = bounds
        return bounds
    }

    private func applyFallbackMaterial(to rootNode: SCNNode, fallbackColor: HorizontalPlatformColor) {
        rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else {
                return
            }

            if geometry.materials.isEmpty {
                let material = SCNMaterial()
                material.diffuse.contents = fallbackColor.withAlphaComponent(0.72)
                material.roughness.contents = 0.82
                geometry.materials = [material]
            }
        }
    }
}

enum BoardSceneFactory {
    fileprivate static let unitsPerMillimeter = 1_000_000.0
    fileprivate static let boardTopHeight = 0.5
    private static let fallbackBoardThickness = 0.8
    /// Vertical clearance between a component model and the nearest board face,
    /// in millimetres. Mirrors `BOARD_OFFSET` constant in
    /// ` so models do not z-fight with the board.
    private static let modelBoardClearance = 0.05
    private static let copperVisualThickness = 0.06
    private static let solderMaskThickness = 0.03
    private static let solderPasteThickness = 0.035
    private static let layerSurfaceGap = 0.001
    private static let maximumPlaneFragments = 400

    private static let maximumViaNodes = 2_500
    private static let maximumConnectionLineDashes = 3_000

    private struct SolderMaskOpening {
        var bounds: HorizontalRect
        var samplePoints: [HorizontalPoint]
        /// The opening's outline(s) in board coordinates, for the clipper.
        var paths: [[HorizontalPoint]]
    }

    private struct PackageViaRenderInfo {
        var marker: HorizontalMarker
        var coveredPadIDs: Set<String>
        var coveredHoleID: String
    }

    private struct MaterialPalette {
        func color(for layer: Int?) -> HorizontalPlatformColor {
            HorizontalDefaultTheme.nsLayerColor(for: layer)
        }

        func padColor(for layer: Int?) -> HorizontalPlatformColor {
            color(for: layer)
        }
    }

    private struct BuildOptions {
        var solderMaskOpenings = true
        var layerArtwork = true
        var decals = true
        var texts = true
        var placedModels = true
        var placeholderPackages = false
        var packagePads = true
        var tracks = true
        var connectionLines = true
        var holes = true
        var originAxes = false
        var orientationAxes = false
        var silkscreenClipping: HorizontalSilkscreenClipping? = nil

        static let full = BuildOptions()
        static let quickLook = BuildOptions(
            solderMaskOpenings: false,
            layerArtwork: false,
            decals: false,
            texts: false,
            placedModels: false,
            placeholderPackages: false,
            packagePads: false,
            tracks: false,
            connectionLines: false,
            holes: false,
            originAxes: false,
            orientationAxes: false
        )
    }

    /// Builds and discards a full scene: for measuring the build itself.
    static func measureSceneBuild(for board: HorizontalBoard) {
        _ = buildScene(for: board, options: .full)
    }

    /// Receives (stage, milliseconds) for every stage of a scene build.
    nonisolated(unsafe) static var stageTimingSink: ((String, Double) -> Void)?

    private static func stage<T>(_ label: String, _ body: () -> T) -> T {
        guard let stageTimingSink else {
            return body()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        stageTimingSink(label, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        return result
    }

    fileprivate static func buildScene(for board: HorizontalBoard, silkscreenClipping: HorizontalSilkscreenClipping? = nil) -> BoardSceneNodes {
        var options = BuildOptions.full
        options.silkscreenClipping = silkscreenClipping
        return buildScene(for: board, options: options)
    }

    fileprivate static func buildQuickLookScene(for board: HorizontalBoard) -> BoardSceneNodes {
        buildScene(for: board, options: .quickLook)
    }

    private static func buildScene(for board: HorizontalBoard, options: BuildOptions) -> BoardSceneNodes {
        let scene = SCNScene()
        scene.background.contents = HorizontalDefaultTheme.backgroundNS

        let bodyBounds = board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds
        let center = bodyBounds.center
        let width = max(bodyBounds.width / unitsPerMillimeter, 10)
        let depth = max(bodyBounds.height / unitsPerMillimeter, 10)
        let thickness = boardBodyThickness(for: board)
        let materialPalette = MaterialPalette()
        let cameraNode = addCamera(to: scene, width: width, depth: depth, projection: .perspective)
        let nodes = BoardSceneNodes(
            scene: scene, cameraNode: cameraNode, board: board,
            boardThickness: thickness, boardWidth: width, boardDepth: depth
        )
        nodes.center = center

        let boardColors = HorizontalBoardColors(
            silkscreen: board.colors.silkscreen,
            solderMask: board.colors.solderMask,
            substrate: board.colors.substrate
        )
        let slabs = stage("substrate") { boardBodyMultiLayerSlabs(
            for: board, center: center, width: width, depth: depth,
            boardThickness: thickness, colors: boardColors
        ) }
        let boardCenterY = boardTopHeight - thickness / 2
        let halfThickness = max(thickness / 2, 0.001)
        for slab in slabs {
            let factor = (slab.midY - boardCenterY) / halfThickness
            for slabNode in slab.nodes {
                nodes.substrateGroup.addChildNode(slabNode)
                nodes.addExplodable(
                    node: slabNode, layer: nil,
                    baseY: Double(slabNode.position.y),
                    explodeFactor: factor
                )
            }
            nodes.substrateFaceMaterials.append(contentsOf: slab.faceMaterials)
            nodes.substrateSideMaterials.append(contentsOf: slab.sideMaterials)
        }

        stage("solder mask") { addSolderMaskSlabs(
            for: board, to: nodes, center: center,
            width: width, depth: depth, boardThickness: thickness,
            colors: boardColors,
            includeOpenings: options.solderMaskOpenings
        ) }

        addBoardPanelOutlines(
            board.boardPanels, toOutline: nodes.outlineGroup,
            toLabels: nodes.panelLabelGroup, center: center
        )
        let silkscreenClips = stage("silkscreen clipping") { options.silkscreenClipping.map { clipping in
            HorizontalSilkscreenClipper.clip(board: board, clipping: clipping)
        } ?? [:] }
        if options.layerArtwork {
            stage("planes") { addPlanes(board.planes, to: nodes, center: center, boardThickness: thickness, materialPalette: materialPalette) }
            stage("keepouts") { addKeepouts(board.keepouts, to: nodes.keepoutGroup, center: center, boardThickness: thickness) }
            stage("board artwork") { addCategorizedArtwork(board.polygons.filter { !isBoardBodyLayer($0.layer) }, lines: board.lines, to: nodes, center: center, boardThickness: thickness, materialPalette: materialPalette, polygonOpacity: 0.34, lineOpacity: 0.58, polygonYOffset: 0.02, lineYOffset: 0.03, silkscreenClips: silkscreenClips) }
            stage("package artwork") { addCategorizedArtwork(board.packagePolygons, lines: board.packageLines, to: nodes, center: center, boardThickness: thickness, materialPalette: materialPalette, polygonOpacity: 0.28, lineOpacity: 0.62, polygonYOffset: 0.04, lineYOffset: 0.05, silkscreenClips: silkscreenClips) }
        }

        if options.decals {
            stage("decals") { addDecals(board.decals, to: nodes, center: center, boardThickness: thickness, materialPalette: materialPalette) }
        }

        if options.texts {
            stage("texts") {
                addCategorizedTexts(board.texts, to: nodes, center: center, boardThickness: thickness, materialPalette: materialPalette, silkscreenClips: silkscreenClips)
                addCategorizedTexts(board.packageTexts, to: nodes, center: center, boardThickness: thickness, materialPalette: materialPalette, silkscreenClips: silkscreenClips)
            }
        }

        if options.placedModels {
            stage("models") { addPackages(board, to: nodes, center: center, boardThickness: thickness, materialPalette: materialPalette) }
        }
        if options.placeholderPackages {
            stage("placeholders") { addPackagePlaceholders(
                board,
                to: nodes,
                center: center,
                boardThickness: thickness,
                materialPalette: materialPalette,
                onlyMissingModels: options.placedModels
            ) }
        }

        let packageViaRenderInfo = stage("package vias") { packageViaRenderInfo(for: board) }
        let packageViaPadIDs = Set(packageViaRenderInfo.flatMap(\.coveredPadIDs))
        if options.packagePads {
            stage("pads") { addPads(
                board.packagePads,
                to: nodes,
                center: center,
                boardThickness: thickness,
                materialPalette: materialPalette,
                excludingPadIDs: packageViaPadIDs
            ) }
        }

        if options.tracks {
            stage("tracks") { addCopperTraceGeometry(
                board.tracks + board.netTies,
                to: nodes,
                center: center,
                boardThickness: thickness,
                materialPalette: materialPalette
            ) }
        }

        if options.connectionLines {
            addConnectionLines(board.connectionLines, to: nodes.connectionGroup, center: center, color: HorizontalDefaultTheme.connectionLineNS)
            addConnectionLines(board.airwires, to: nodes.connectionGroup, center: center, color: HorizontalDefaultTheme.airwireNS)
        }

        if options.holes {
            // Drilled holes are the cutouts through the substrate, copper and
            // mask; nothing is drawn in the void itself (the via and
            // through-hole barrels are copper and live with the vias).
            let renderedVias = board.vias + packageViaRenderInfo.map(\.marker)
            nodes.vias = Array(renderedVias.prefix(maximumViaNodes))
        }

        if options.originAxes {
            addBoardOriginAxes(to: nodes.originGroup, center: center, width: width, depth: depth)
        }

        addLighting(to: scene, width: width, depth: depth)
        if options.orientationAxes {
            addOrientationAxes(to: nodes.orientationAxesGroup, width: width, depth: depth)
        }

        return nodes
    }

    fileprivate static func explodeFactor(
        for layer: Int?,
        board: HorizontalBoard,
        boardThickness: Double
    ) -> Double {
        guard let layer else { return 1.0 }

        let centerY = boardTopHeight - boardThickness / 2
        let halfThickness = max(boardThickness / 2, 0.001)

        if HorizontalBoardLayers.isCopper(layer) {
            let layerY = copperLayerStackY(layer, board: board, boardThickness: boardThickness)
            return (layerY - centerY) / halfThickness
        }

        let sign: Double = isBottomSideLayer(layer) ? -1 : 1
        switch HorizontalBoardLayers.category(for: layer) {
        case .solderMask: return sign * 1.5
        case .silkscreen: return sign * 2.0
        case .paste:      return sign * 2.5
        default:          return sign * 1.0
        }
    }

    private static func layerSeparationOffset(for layer: Int?, amount: Double) -> Double {
        guard let layer, amount > 0 else { return 0 }
        if isBottomSideLayer(layer) { return -amount }
        if HorizontalBoardLayers.isCopper(layer), layer != HorizontalBoardLayers.topCopper { return 0 }
        return amount
    }

    private static func layerGroupForCategory(_ layer: Int?, nodes: BoardSceneNodes) -> SCNNode {
        guard let layer else { return nodes.copperGroup }
        switch HorizontalBoardLayers.category(for: layer) {
        case .silkscreen: return nodes.silkscreenGroup
        case .solderMask: return nodes.solderMaskGroup
        case .paste: return nodes.pasteGroup
        default: return nodes.copperGroup
        }
    }

    private struct SubstrateSlab {
        var nodes: [SCNNode]
        var faceMaterials: [SCNMaterial]
        var sideMaterials: [SCNMaterial]
        var midY: Double
    }

    private static func boardBodyMultiLayerSlabs(
        for board: HorizontalBoard,
        center: HorizontalPoint,
        width: Double,
        depth: Double,
        boardThickness: Double,
        colors: HorizontalBoardColors
    ) -> [SubstrateSlab] {
        let descending = board.stackupLayers.sorted { $0.layer > $1.layer }
        let dielectricLayers = descending.filter {
            $0.substrateThickness > 0 && $0.layer != HorizontalBoardLayers.bottomCopper
        }

        // Every drilled hole — free, via or package — comes out of the
        // substrate, so a through-hole part's pins show as holes, not as
        // pads sitting on solid board.
        let drillCutouts = drillCutoutPaths(for: nil, board: board)

        // One footprint per outline, extruded once per dielectric layer.
        let templates = boardOutlinePolygons(from: board.polygons).compactMap {
            boardBodyTemplate(for: $0, cutouts: drillCutouts)
        }

        if dielectricLayers.count <= 1 {
            let substrateThickness = dielectricThickness(for: board, fallback: boardThickness)
            let outlineResults = templates.compactMap {
                boardBodyNodeAndMaterials(
                    template: $0, center: center, thickness: substrateThickness, topY: boardTopHeight, colors: colors
                )
            }
            if outlineResults.isEmpty {
                let (node, face, side) = rectangularBoardNodeAndMaterials(
                    width: width, depth: depth, thickness: substrateThickness, topY: boardTopHeight, colors: colors
                )
                return [SubstrateSlab(nodes: [node], faceMaterials: [face], sideMaterials: [side],
                                      midY: boardTopHeight - substrateThickness / 2)]
            }
            var slabNodes: [SCNNode] = []
            var faceMats: [SCNMaterial] = []
            var sideMats: [SCNMaterial] = []
            for (node, face, side) in outlineResults {
                slabNodes.append(node)
                faceMats.append(face)
                sideMats.append(side)
            }
            return [SubstrateSlab(nodes: slabNodes, faceMaterials: faceMats, sideMaterials: sideMats,
                                  midY: boardTopHeight - substrateThickness / 2)]
        }

        let outlines = boardOutlinePolygons(from: board.polygons)
        var result: [SubstrateSlab] = []
        var y = boardTopHeight

        for entry in descending {
            if entry.layer == HorizontalBoardLayers.bottomCopper { continue }
            if entry.layer != HorizontalBoardLayers.topCopper {
                y -= max(entry.copperThickness / unitsPerMillimeter, 0)
            }
            let slabThickness = entry.substrateThickness / unitsPerMillimeter
            guard slabThickness > 0.001 else {
                continue
            }

            let slabTopY = y
            y -= slabThickness
            let slabMidY = (slabTopY + y) / 2
            let chamferSafe = min(max(slabThickness, 0.05), 6.0)

            if outlines.isEmpty {
                let (node, face, side) = rectangularBoardNodeAndMaterials(
                    width: width, depth: depth, thickness: chamferSafe, topY: slabTopY, colors: colors
                )
                result.append(SubstrateSlab(nodes: [node], faceMaterials: [face], sideMaterials: [side], midY: slabMidY))
            } else {
                var slabNodes: [SCNNode] = []
                var faceMats: [SCNMaterial] = []
                var sideMats: [SCNMaterial] = []
                for template in templates {
                    if let (node, face, side) = boardBodyNodeAndMaterials(
                        template: template, center: center, thickness: chamferSafe, topY: slabTopY, colors: colors
                    ) {
                        slabNodes.append(node)
                        faceMats.append(face)
                        sideMats.append(side)
                    }
                }
                if !slabNodes.isEmpty {
                    result.append(SubstrateSlab(nodes: slabNodes, faceMaterials: faceMats, sideMaterials: sideMats, midY: slabMidY))
                }
            }
        }

        return result
    }

    private static func addSolderMaskSlabs(
        for board: HorizontalBoard,
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        width: Double,
        depth: Double,
        boardThickness: Double,
        colors: HorizontalBoardColors,
        includeOpenings: Bool = true
    ) {
        let maskColor = colors.solderMask?.nsColor
            ?? HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.topMask)
        let outlines = boardOutlinePolygons(from: board.polygons)
        // The pad outlines serve both mask layers; unioning seven thousand
        // pads is worth doing once.
        let padFragments = includeOpenings ? horizonPadOutlineFragments(board.packagePads) : []

        // 3D mesh places soldermask just outside the corresponding
        // copper face (`top copper thickness + 1e-3` on top, outside the
        // bottom copper on bottom). Keep the same ordering in SceneKit's
        // top-surface coordinate convention.
        let topY = solderMaskTopSurfaceHeight(for: HorizontalBoardLayers.topMask, board: board, boardThickness: boardThickness)
        let bottomY = solderMaskTopSurfaceHeight(for: HorizontalBoardLayers.bottomMask, board: board, boardThickness: boardThickness)

        for (slabTopY, layer) in [(topY, HorizontalBoardLayers.topMask), (bottomY, HorizontalBoardLayers.bottomMask)] {
            let openings = stage("mask: openings") { includeOpenings ? solderMaskOpenings(for: layer, board: board, center: center, padFragments: padFragments) : [] }
            if outlines.isEmpty {
                let node = rectangularSolderMaskNode(
                    width: width, depth: depth, center: center, thickness: solderMaskThickness,
                    topY: slabTopY, color: maskColor, openings: openings.flatMap(\.paths)
                )
                nodes.addExplodable(node: node, layer: layer, baseY: Double(node.position.y))
                nodes.solderMaskGroup.addChildNode(node)
            } else {
                for outline in outlines {
                    let outlineOpenings = stage("mask: filter") { openings
                        .filter { solderMaskOpening($0, intersects: outline) }
                        .flatMap(\.paths) }
                    let maskNode = stage("mask: node") {
                        solderMaskNode(
                            for: outline, center: center, openings: outlineOpenings,
                            thickness: solderMaskThickness, topY: slabTopY, color: maskColor
                        )
                    }
                    guard let node = maskNode else { continue }
                    nodes.addExplodable(node: node, layer: layer, baseY: Double(node.position.y))
                    nodes.solderMaskGroup.addChildNode(node)
                }
            }
        }
    }

    private static func solderMaskNode(
        for outline: HorizontalPolygon,
        center: HorizontalPoint,
        openings: [[HorizontalPoint]],
        thickness: Double,
        topY: Double,
        color: HorizontalPlatformColor
    ) -> SCNNode? {
        let fragments = outlineFragments(for: outline, cutouts: openings)
        guard !fragments.isEmpty else {
            return nil
        }
        let template = ExtrudedMeshTemplate(fragments)
        guard !template.isEmpty else {
            return nil
        }
        let material = solderMaskMaterial(color: color)
        return extrudedFragmentsNode(
            template,
            center: center,
            thickness: thickness,
            topY: topY,
            faceMaterial: material,
            sideMaterial: material
        )
    }

    private static func rectangularSolderMaskNode(
        width: Double,
        depth: Double,
        center: HorizontalPoint,
        thickness: Double,
        topY: Double,
        color: HorizontalPlatformColor,
        openings: [[HorizontalPoint]] = []
    ) -> SCNNode {
        if !openings.isEmpty {
            let halfWidth = width * unitsPerMillimeter / 2
            let halfDepth = depth * unitsPerMillimeter / 2
            let rectangle = HorizontalPolygon(
                id: "solder-mask-rectangle",
                vertices: [
                    HorizontalPoint(x: center.x - halfWidth, y: center.y - halfDepth),
                    HorizontalPoint(x: center.x + halfWidth, y: center.y - halfDepth),
                    HorizontalPoint(x: center.x + halfWidth, y: center.y + halfDepth),
                    HorizontalPoint(x: center.x - halfWidth, y: center.y + halfDepth),
                ],
                layer: nil
            )
            if let node = solderMaskNode(for: rectangle, center: center, openings: openings, thickness: thickness, topY: topY, color: color) {
                return node
            }
        }

        let material = solderMaskMaterial(color: color)
        let geometry = SCNBox(width: width, height: thickness, length: depth, chamferRadius: 0)
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.position.y = horizonSceneScalar(topY - thickness / 2)
        return node
    }

    private static func solderMaskMaterial(color: HorizontalPlatformColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.roughness.contents = 0.6
        material.transparency = 0.7
        material.isDoubleSided = true
        return material
    }

    private static func solderMaskOpenings(
        for layer: Int,
        board: HorizontalBoard,
        center: HorizontalPoint,
        padFragments: [HorizontalPadOutlineFragment]
    ) -> [SolderMaskOpening] {
        var openings: [SolderMaskOpening] = []
        let polygons = board.polygons + board.packagePolygons
        openings.reserveCapacity(polygons.count)

        for polygon in polygons where polygon.layer == layer {
            let points = cleanedClosedScenePoints(polygon.renderVertices(arcPrecision: 32))
            guard points.count >= 3 else {
                continue
            }
            openings.append(SolderMaskOpening(
                bounds: HorizontalRect(points: points),
                samplePoints: points,
                paths: [points]
            ))
        }
        for pad in padFragments where pad.layer == layer {
            let cleanedPaths = pad.paths.map(cleanedClosedScenePoints).filter { $0.count >= 3 }
            guard !cleanedPaths.isEmpty else {
                continue
            }
            openings.append(SolderMaskOpening(
                bounds: HorizontalRect(points: cleanedPaths.flatMap { $0 }),
                samplePoints: cleanedPaths.flatMap { $0 },
                paths: cleanedPaths
            ))
        }

        // Via openings: the padstack's expanded mask circle, the same outline
        // the canvas draws and the Gerber export writes. A tented padstack
        // has none, so those vias stay under the mask here too.
        for via in board.vias {
            let opening = via.maskOutline(on: layer)
            guard opening.count >= 3 else {
                continue
            }
            let points = cleanedClosedScenePoints(opening)
            guard points.count >= 3 else {
                continue
            }
            openings.append(SolderMaskOpening(
                bounds: HorizontalRect(points: points),
                samplePoints: points,
                paths: [points]
            ))
        }

        let lines = board.lines + board.packageLines
        for line in lines where line.layer == layer {
            let points = cleanedOpenScenePoints(line.pathPoints)
            let strokes = HorizontalSilkscreenClipper.strokePaths(for: line)
            guard !strokes.isEmpty else {
                continue
            }
            let bounds = HorizontalRect(points: points).expanded(by: max(line.width, 0) / 2)
            openings.append(SolderMaskOpening(bounds: bounds, samplePoints: points, paths: strokes))
        }

        let arcs = board.arcs + board.packageArcs
        for arc in arcs where arc.layer == layer {
            let line = HorizontalSegment(
                id: arc.id, from: arc.from, to: arc.to, width: arc.width,
                layer: arc.layer, center: arc.center, reverse: arc.reverse, netID: arc.netID
            )
            let points = cleanedOpenScenePoints(line.pathPoints)
            let strokes = HorizontalSilkscreenClipper.strokePaths(for: line)
            guard !strokes.isEmpty else {
                continue
            }
            let bounds = HorizontalRect(points: points).expanded(by: max(arc.width, 0) / 2)
            openings.append(SolderMaskOpening(bounds: bounds, samplePoints: points, paths: strokes))
        }

        return openings
    }

    private static func solderMaskOpening(
        _ opening: SolderMaskOpening,
        intersects outline: HorizontalPolygon
    ) -> Bool {
        let outlinePoints = cleanedClosedScenePoints(outline.renderVertices(arcPrecision: 32))
        guard outlinePoints.count >= 3 else {
            return false
        }

        let outlineBounds = HorizontalRect(points: outlinePoints)
        guard outlineBounds.intersects(opening.bounds) else {
            return false
        }

        if point(opening.bounds.center, isInside: outlinePoints) {
            return true
        }
        if opening.samplePoints.contains(where: { point($0, isInside: outlinePoints) }) {
            return true
        }
        return outlinePoints.contains { point in
            rect(opening.bounds, contains: point)
        }
    }

    private static func point(_ point: HorizontalPoint, isInside polygon: [HorizontalPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }

        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let x = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < x {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    private static func rect(_ rect: HorizontalRect, contains point: HorizontalPoint) -> Bool {
        !rect.isEmpty
            && point.x >= rect.minX
            && point.x <= rect.maxX
            && point.y >= rect.minY
            && point.y <= rect.maxY
    }

    private static func addBoardPanelOutlines(
        _ panels: [HorizontalBoardPanel],
        toOutline outlineGroup: SCNNode,
        toLabels labelGroup: SCNNode,
        center: HorizontalPoint
    ) {
        let material = SCNMaterial()
        material.diffuse.contents = HorizontalDefaultTheme.textOverlayNS.withAlphaComponent(0.42)
        material.emission.contents = HorizontalDefaultTheme.textOverlayNS.withAlphaComponent(0.08)

        for panel in panels where !panel.bounds.isEmpty {
            let y = boardTopHeight + 0.22
            let corners = [
                HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.minY),
                HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.minY),
                HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.maxY),
                HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.maxY)
            ].map { scenePosition($0, center: center, y: y) }

            for index in corners.indices {
                let nextIndex = index == corners.index(before: corners.endIndex) ? corners.startIndex : corners.index(after: index)
                if let node = cylinderNode(from: corners[index], to: corners[nextIndex], radius: 0.018, material: material) {
                    outlineGroup.addChildNode(node)
                }
            }

            if !panel.boardName.isEmpty {
                let labelPosition = scenePosition(panel.bounds.center, center: center, y: boardTopHeight + 0.7)
                labelGroup.addChildNode(panelLabelNode(panel.boardName, position: labelPosition))
            }
        }
    }

    private static func panelLabelNode(_ label: String, position: SCNVector3) -> SCNNode {
        let text = SCNText(string: label, extrusionDepth: 0.008)
        #if canImport(AppKit)
        text.font = NSFont.systemFont(ofSize: 1, weight: .semibold)
        #else
        text.font = UIFont.systemFont(ofSize: 1, weight: .semibold)
        #endif
        text.flatness = 0.25
        text.firstMaterial?.diffuse.contents = HorizontalDefaultTheme.textOverlayNS.withAlphaComponent(0.62)
        text.firstMaterial?.emission.contents = HorizontalDefaultTheme.textOverlayNS.withAlphaComponent(0.08)

        let node = SCNNode(geometry: text)
        let bounds = text.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(
            (bounds.max.x + bounds.min.x) / 2,
            (bounds.max.y + bounds.min.y) / 2,
            0
        )
        node.scale = SCNVector3(0.22, 0.22, 0.22)
        node.position = position
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    private static func boardBodyTemplate(
        for outline: HorizontalPolygon,
        cutouts: [[HorizontalPoint]]
    ) -> ExtrudedMeshTemplate? {
        let fragments = stage("substrate: fragments") { outlineFragments(for: outline, cutouts: cutouts) }
        guard !fragments.isEmpty else {
            return nil
        }
        let template = stage("substrate: triangles") { ExtrudedMeshTemplate(fragments) }
        return template.isEmpty ? nil : template
    }

    private static func boardBodyNodeAndMaterials(
        template: ExtrudedMeshTemplate,
        center: HorizontalPoint,
        thickness: Double,
        topY: Double,
        colors: HorizontalBoardColors
    ) -> (node: SCNNode, face: SCNMaterial, side: SCNMaterial)? {
        let substrateColor = colors.substrate?.nsColor
            ?? HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.outline)
        let bodyMaterial = SCNMaterial()
        bodyMaterial.diffuse.contents = substrateColor
        bodyMaterial.roughness.contents = 0.85
        bodyMaterial.transparency = 1

        let sideMaterial = SCNMaterial()
        sideMaterial.diffuse.contents = substrateColor
        sideMaterial.roughness.contents = 0.9
        sideMaterial.transparency = 1

        let meshNode = stage("substrate: mesh") {
            extrudedFragmentsNode(
                template,
                center: center,
                thickness: thickness,
                topY: topY,
                faceMaterial: bodyMaterial,
                sideMaterial: sideMaterial
            )
        }
        guard let node = meshNode else {
            return nil
        }
        return (node, bodyMaterial, sideMaterial)
    }

    private static func rectangularBoardNodeAndMaterials(
        width: Double, depth: Double, thickness: Double, topY: Double, colors: HorizontalBoardColors
    ) -> (node: SCNNode, face: SCNMaterial, side: SCNMaterial) {
        let substrateColor = colors.substrate?.nsColor
            ?? HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.outline)
        let bodyMaterial = SCNMaterial()
        bodyMaterial.diffuse.contents = substrateColor
        bodyMaterial.roughness.contents = 0.85
        bodyMaterial.transparency = 1

        let sideMaterial = SCNMaterial()
        sideMaterial.diffuse.contents = substrateColor
        sideMaterial.roughness.contents = 0.9
        sideMaterial.transparency = 1

        let boardGeometry = SCNBox(width: width, height: thickness, length: depth, chamferRadius: min(0.25, thickness * 0.3))
        boardGeometry.materials = [
            sideMaterial,
            sideMaterial,
            sideMaterial,
            sideMaterial,
            bodyMaterial,
            bodyMaterial
        ]
        let node = SCNNode(geometry: boardGeometry)
        node.position.y = horizonSceneScalar(topY - thickness / 2)
        return (node, bodyMaterial, sideMaterial)
    }

    private static func boardBodyThickness(for board: HorizontalBoard) -> Double {
        let stackDepth = stackDepthBelowTopSubstrate(for: board)
        guard stackDepth > 0 else {
            return fallbackBoardThickness
        }

        return min(max(stackDepth, 0.2), 6.0)
    }

    private static func stackDepthBelowTopSubstrate(for board: HorizontalBoard) -> Double {
        let layers = board.stackupLayers.filter { HorizontalBoardLayers.isCopper($0.layer) }
        guard !layers.isEmpty else {
            return board.totalSubstrateThickness / unitsPerMillimeter
        }

        let topCopper = copperThickness(for: HorizontalBoardLayers.topCopper, board: board, fallback: 0)
        let total = layers.reduce(0.0) { partial, layer in
            partial
                + max(layer.copperThickness / unitsPerMillimeter, 0)
                + max(layer.substrateThickness / unitsPerMillimeter, 0)
        } - topCopper
        return max(total, board.totalSubstrateThickness / unitsPerMillimeter)
    }

    private static func dielectricThickness(for board: HorizontalBoard, fallback: Double) -> Double {
        let thickness = board.totalSubstrateThickness / unitsPerMillimeter
        return thickness > 0 ? thickness : fallback
    }

    fileprivate static func copperThickness(
        for layer: Int?,
        board: HorizontalBoard?,
        fallback: Double = copperVisualThickness
    ) -> Double {
        guard let layer,
              let board,
              let stackupLayer = board.stackupLayers.first(where: { $0.layer == layer }) else {
            return fallback
        }
        let thickness = stackupLayer.copperThickness / unitsPerMillimeter
        return thickness > 0 ? thickness : fallback
    }

    private static func boardOutlinePolygons(from polygons: [HorizontalPolygon]) -> [HorizontalPolygon] {
        polygons
            .filter { polygon in
                guard let layer = polygon.layer else {
                    return false
                }
                return HorizontalBoardLayers.isOutline(layer) && polygon.renderVertices(arcPrecision: 32).count >= 3
            }
            .sorted { lhs, rhs in
                abs(polygonArea(lhs.renderVertices(arcPrecision: 32))) > abs(polygonArea(rhs.renderVertices(arcPrecision: 32)))
            }
    }

    private static func polygonArea(_ vertices: [HorizontalPoint]) -> Double {
        guard vertices.count >= 3 else {
            return 0
        }

        return zip(vertices, vertices.dropFirst() + [vertices[0]]).reduce(0) { area, pair in
            area + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        } / 2
    }

    private static func addPackages(
        _ board: HorizontalBoard,
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        boardThickness: Double,
        materialPalette: MaterialPalette
    ) {
        for package in board.packages {
            guard let node = modelPackageNode(
                for: package,
                board: board,
                center: center,
                boardThickness: boardThickness,
                layerSeparation: 0,
                materialPalette: materialPalette
            ) else {
                continue
            }
            let baseY = package.mirrored
                ? copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: boardThickness) - modelBoardClearance
                : copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: boardThickness) + modelBoardClearance
            let modelFactor: Double = package.mirrored ? -3.0 : 3.0
            nodes.addExplodable(node: node, layer: nil, baseY: baseY, explodeFactor: modelFactor)
            if package.componentDetails?.noPopulate == true {
                nodes.noPopulateModelGroup.addChildNode(node)
            } else {
                nodes.modelGroup.addChildNode(node)
            }
        }
    }

    private static func addPackagePlaceholders(
        _ board: HorizontalBoard,
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        boardThickness: Double,
        materialPalette: MaterialPalette,
        onlyMissingModels: Bool
    ) {
        for package in board.packages {
            if onlyMissingModels && package.model3D != nil {
                continue
            }
            let footprintBounds = packageFootprintBounds(for: package.id, board: board)
            let node = packageNode(
                for: package,
                footprintBounds: footprintBounds,
                board: board,
                center: center,
                boardThickness: boardThickness,
                layerSeparation: 0,
                materialPalette: materialPalette
            )
            let baseY = package.mirrored
                ? copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: boardThickness)
                : copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: boardThickness)
            let modelFactor: Double = package.mirrored ? -3.0 : 3.0
            nodes.addExplodable(node: node, layer: nil, baseY: baseY, explodeFactor: modelFactor)
            nodes.placeholderModelGroup.addChildNode(node)
        }
    }

    private static func modelPackageNode(
        for package: HorizontalPlacement,
        board: HorizontalBoard,
        center: HorizontalPoint,
        boardThickness: Double,
        layerSeparation: Double,
        materialPalette: MaterialPalette
    ) -> SCNNode? {
        guard let model = package.model3D else {
            return nil
        }

        let packageColor = package.mirrored
            ? materialPalette.color(for: HorizontalBoardLayers.bottomCopper)
            : materialPalette.color(for: HorizontalBoardLayers.topCopper)

        guard let contentNode = HorizontalPackage3DNodeCache.shared.node(
            for: model,
            fallbackColor: packageColor
        ) else {
            return nil
        }

        let root = SCNNode()
        root.name = "package-\(package.id)-model"
        // Lift the component clear of the board face. The model's package-local
        // x/y/z offset is applied below, before the board placement transform,
        // matching canvas3d model shader.
        let surfaceY = package.mirrored
            ? copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: boardThickness) - modelBoardClearance - layerSeparation
            : copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: boardThickness) + modelBoardClearance + layerSeparation
        root.position = scenePosition(
            package.position,
            center: center,
            y: surfaceY
        )

        let placementNode = SCNNode()
        placementNode.transform = modelBoardPlacementTransform(for: package)

        let modelTransformNode = SCNNode()
        modelTransformNode.transform = modelLocalTransform(for: model)
        modelTransformNode.addChildNode(contentNode)
        placementNode.addChildNode(modelTransformNode)
        root.addChildNode(placementNode)
        return root
    }

    private static func packageNode(
        for package: HorizontalPlacement,
        footprintBounds: HorizontalRect?,
        board: HorizontalBoard,
        center: HorizontalPoint,
        boardThickness: Double,
        layerSeparation: Double,
        materialPalette: MaterialPalette
    ) -> SCNNode {
        let fallbackSize = 2.2
        let footprintWidth = footprintBounds.map { max($0.width / unitsPerMillimeter, 0.8) } ?? fallbackSize
        let footprintDepth = footprintBounds.map { max($0.height / unitsPerMillimeter, 0.8) } ?? fallbackSize
        let height = componentHeight(width: footprintWidth, depth: footprintDepth)
        let geometry = SCNBox(
            width: footprintWidth,
            height: height,
            length: footprintDepth,
            chamferRadius: min(max(min(footprintWidth, footprintDepth) * 0.04, 0.04), 0.16)
        )
        let packageColor = package.mirrored
            ? materialPalette.color(for: HorizontalBoardLayers.bottomCopper)
            : materialPalette.color(for: HorizontalBoardLayers.topCopper)
        geometry.firstMaterial?.diffuse.contents = packageColor
        geometry.firstMaterial?.roughness.contents = 0.8
        geometry.firstMaterial?.transparency = 0.42

        let packageCenter = footprintBounds?.center ?? package.position
        let clearance = 0.24
        let surfaceY = package.mirrored
            ? copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: boardThickness)
            : copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: boardThickness)
        let yPosition = package.mirrored
            ? surfaceY - clearance - height / 2 - layerSeparation
            : surfaceY + clearance + height / 2 + layerSeparation
        let node = SCNNode(geometry: geometry)
        node.position = scenePosition(packageCenter, center: center, y: yPosition)
        return node
    }

    private static func modelOffsetVector(for model: HorizontalPackage3DModel) -> SCNVector3 {
        SCNVector3(
            horizonSceneScalar(model.x / unitsPerMillimeter),
            horizonSceneScalar(model.z / unitsPerMillimeter),
            horizonSceneScalar(-model.y / unitsPerMillimeter)
        )
    }

    // Horizon's face vertex shader: `rot = R(x, roll) * R(y, pitch) * R(z, yaw)`
    // applied to column vectors, so the yaw turns the mesh first, the pitch
    // second and the roll last, and only then is the package-local x/y/z
    // offset added, unrotated. (Its `rotationMatrix` fills GLSL's
    // column-major mat4 with a row-major rotation, which turns by the
    // negated angle; the signs below fold that in together with the z-up to
    // y-up axis swap: Horizon y is SceneKit -z, Horizon z is SceneKit y.)
    // SceneKit's `SCNMatrix4Mult(a, b)` applies `a` first, so the order here
    // reads in application order. Parts with two rotations — a pitch and a
    // yaw — land wrongly when any of this is composed the other way round.
    static func modelLocalTransform(for model: HorizontalPackage3DModel) -> SCNMatrix4 {
        let roll = SCNMatrix4MakeRotation(-angleRadians(model.roll), 1, 0, 0)
        let pitch = SCNMatrix4MakeRotation(angleRadians(model.pitch), 0, 0, 1)
        let yaw = SCNMatrix4MakeRotation(-angleRadians(model.yaw), 0, 1, 0)
        let rotation = SCNMatrix4Mult(SCNMatrix4Mult(yaw, pitch), roll)
        let offset = modelOffsetVector(for: model)
        let translation = SCNMatrix4MakeTranslation(offset.x, offset.y, offset.z)
        return SCNMatrix4Mult(rotation, translation)
    }

    private static func modelBoardPlacementTransform(for package: HorizontalPlacement) -> SCNMatrix4 {
        let angle = angleRadians(package.angle)
        if package.mirrored {
            let bottomFlip = SCNMatrix4MakeRotation(horizonSceneScalar(Double.pi), 0, 0, 1)
            let bottomRotation = SCNMatrix4MakeRotation(angle, 0, 1, 0)
            return SCNMatrix4Mult(bottomFlip, bottomRotation)
        }

        return SCNMatrix4MakeRotation(angle, 0, 1, 0)
    }

    private static func packageFootprintBounds(for packageID: String, board: HorizontalBoard) -> HorizontalRect? {
        let normalizedPackageID = normalizedID(packageID)
        let padPoints = board.packagePads
            .filter { geometryBelongsToPackage($0.id, normalizedPackageID: normalizedPackageID) }
            .flatMap { $0.renderVertices(arcPrecision: 24) }
        let polygonPoints = board.packagePolygons
            .filter { geometryBelongsToPackage($0.id, normalizedPackageID: normalizedPackageID) }
            .flatMap { $0.renderVertices(arcPrecision: 24) }
        let linePoints = board.packageLines
            .filter { geometryBelongsToPackage($0.id, normalizedPackageID: normalizedPackageID) }
            .flatMap { [$0.from, $0.to] }
        let holePoints = board.packageHoles
            .filter { geometryBelongsToPackage($0.id, normalizedPackageID: normalizedPackageID) }
            .map(\.position)
        let points = padPoints + polygonPoints + linePoints + holePoints

        let bounds = HorizontalRect(points: points)
        return bounds.isEmpty ? nil : bounds
    }

    private static func geometryBelongsToPackage(_ geometryID: String, normalizedPackageID: String) -> Bool {
        let normalizedGeometryID = normalizedID(geometryID)
        return normalizedGeometryID == normalizedPackageID
            || normalizedGeometryID.hasPrefix("\(normalizedPackageID)/")
    }

    private static func componentHeight(width: Double, depth: Double) -> Double {
        let smallerDimension = min(width, depth)
        let largerDimension = max(width, depth)
        let baseHeight = min(max(smallerDimension * 0.22, 0.45), 1.6)
        return largerDimension > 10 ? max(baseHeight, 1.1) : baseHeight
    }

    private static func angleRadians(_ angle: Int) -> HorizontalSceneScalar {
        horizonSceneScalar(Double(angle) / 65_536.0 * Double.pi * 2)
    }

    private static func normalizedID(_ id: String) -> String {
        id.lowercased()
    }

    private static func addPads(
        _ pads: [HorizontalPolygon],
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        boardThickness: Double,
        materialPalette: MaterialPalette,
        excludingPadIDs: Set<String> = []
    ) {
        let renderPads = pads.filter {
            !excludingPadIDs.contains($0.id)
                && !isExcludedFrom3DScene($0.layer)
                && !isSolderMaskLayer($0.layer)
        }
        let board = nodes.board
        // A pad's own drilled holes come out of its copper; a hole drilled
        // elsewhere on the board that lands inside the pad does too.
        let packageHolesByPadID = Dictionary(grouping: board.packageHoles) { packagePadID(for: $0.id) ?? $0.id }
        let otherHoles = board.holes + board.viaHoles
        for pad in horizonPadOutlineFragments(renderPads) {
            var cutouts = [[HorizontalPoint]]()
            if let padID = packagePadID(for: pad.id) {
                for hole in packageHolesByPadID[padID] ?? [] {
                    let points = cleanedClosedScenePoints(hole.outlinePoints(precision: 48))
                    if points.count >= 3 {
                        cutouts.append(points)
                    }
                }
            }
            let padBounds = HorizontalRect(points: pad.paths.flatMap { $0 })
            for hole in otherHoles where padBounds.contains(hole.position) {
                let points = cleanedClosedScenePoints(hole.outlinePoints(precision: 48))
                if points.count >= 3 {
                    cutouts.append(points)
                }
            }
            var paths = pad.paths
            if !cutouts.isEmpty {
                let fragments = clippedSceneFragments(subjects: pad.paths, cutouts: cutouts)
                guard !fragments.isEmpty else {
                    // The hole swallowed the pad: nothing left to render.
                    continue
                }
                paths = fragments.flatMap { $0 }
            }
            guard let node = padNode(
                pad,
                paths: paths,
                center: center,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: 0,
                materialPalette: materialPalette
            ) else {
                continue
            }
            node.name = "layer:\(pad.layer ?? -1)"
            let group = layerGroupForCategory(pad.layer, nodes: nodes)
            let baseY = padTopSurfaceHeight(for: pad.layer, board: board, boardThickness: boardThickness)
            nodes.addExplodable(node: node, layer: pad.layer, baseY: baseY)
            group.addChildNode(node)
        }
    }

    private static func packageViaRenderInfo(for board: HorizontalBoard) -> [PackageViaRenderInfo] {
        guard !board.packageHoles.isEmpty, !board.packagePads.isEmpty else {
            return []
        }

        let padsByPackagePadID = Dictionary(grouping: board.packagePads) { packagePadID(for: $0.id) ?? $0.id }
        let defaultConnectedLayers = boardCopperLayers(for: board)

        return board.packageHoles.compactMap { hole -> PackageViaRenderInfo? in
            guard hole.plated,
                  hole.shape == .round || hole.effectiveLength <= hole.diameter,
                  let padID = packagePadID(for: hole.id) else {
                return nil
            }

            let copperPads = (padsByPackagePadID[padID] ?? []).filter { pad in
                guard let layer = pad.layer else {
                    return false
                }
                return HorizontalBoardLayers.isCopper(layer)
            }

            let roundPads = copperPads.compactMap { pad -> (pad: HorizontalPolygon, diameter: Double)? in
                guard let diameter = roundPadDiameter(pad, around: hole.position) else {
                    return nil
                }
                return (pad, diameter)
            }
            guard !roundPads.isEmpty else {
                return nil
            }

            let padLayers = Set(roundPads.compactMap(\.pad.layer).filter(HorizontalBoardLayers.isCopper))
            let connectedLayers = padLayers.count >= 2
                ? padLayers.sorted(by: >)
                : defaultConnectedLayers
            let padDiameter = roundPads.map(\.diameter).max() ?? hole.diameter
            let outerDiameter = max(padDiameter, hole.diameter * 1.25)
            let marker = HorizontalMarker(
                id: "\(hole.id)/package-via",
                position: hole.position,
                size: outerDiameter,
                holeSize: hole.diameter,
                layer: nil,
                connectedLayers: connectedLayers,
                netID: hole.netID
            )

            return PackageViaRenderInfo(
                marker: marker,
                coveredPadIDs: Set(roundPads.map(\.pad.id)),
                coveredHoleID: hole.id
            )
        }
    }

    private static func packagePadID(for geometryID: String) -> String? {
        guard let padRange = geometryID.range(of: "/pad/") else {
            return nil
        }
        let afterPad = geometryID[padRange.upperBound...]
        let padEnd = afterPad.firstIndex(of: "/") ?? geometryID.endIndex
        return String(geometryID[..<padEnd])
    }

    private static func roundPadDiameter(_ pad: HorizontalPolygon, around center: HorizontalPoint) -> Double? {
        let vertices = pad.renderVertices(arcPrecision: 32)
        guard vertices.count >= 8 else {
            return nil
        }

        let bounds = HorizontalRect(points: vertices)
        let width = bounds.width
        let height = bounds.height
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              min(width, height) / max(width, height) > 0.92 else {
            return nil
        }

        let radii = vertices.map { ($0 - center).length }
        guard let minimumRadius = radii.min(),
              let maximumRadius = radii.max(),
              maximumRadius.isFinite,
              maximumRadius > 0,
              minimumRadius / maximumRadius > 0.88 else {
            return nil
        }

        return max(width, height, maximumRadius * 2)
    }

    private static func boardCopperLayers(for board: HorizontalBoard) -> [Int] {
        let layers = board.stackupLayers
            .map(\.layer)
            .filter(HorizontalBoardLayers.isCopper)
            .sorted(by: >)
        return layers.isEmpty
            ? [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
            : layers
    }

    private static func addCategorizedArtwork(
        _ polygons: [HorizontalPolygon],
        lines: [HorizontalSegment],
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        boardThickness: Double,
        materialPalette: MaterialPalette,
        polygonOpacity: CGFloat,
        lineOpacity: CGFloat,
        polygonYOffset: Double,
        lineYOffset: Double,
        silkscreenClips: [Int: HorizontalClippedSilkscreenLayer] = [:]
    ) {
        let board = nodes.board
        for polygon in polygons where !isExcludedFrom3DScene(polygon.layer) && !isPackageOrAssemblyLayer(polygon.layer) && !isSolderMaskLayer(polygon.layer) {
            if let layer = polygon.layer, let clipped = silkscreenClips[layer]?.object(polygon.id) {
                addClippedSilkscreen(
                    clipped, layer: layer, to: nodes, center: center, materialPalette: materialPalette, opacity: 0.72,
                    height: overlayHeight(for: layer, board: board, boardThickness: boardThickness) + overlayArtworkYOffset(for: layer, fallback: polygonYOffset)
                )
                continue
            }
            let effectiveOpacity: CGFloat
            if let layer = polygon.layer {
                switch HorizontalBoardLayers.category(for: layer) {
                case .silkscreen: effectiveOpacity = 0.72
                case .solderMask: effectiveOpacity = 0.55
                default: effectiveOpacity = polygonOpacity
                }
            } else {
                effectiveOpacity = polygonOpacity
            }
            let effectiveYOffset = overlayArtworkYOffset(for: polygon.layer, fallback: polygonYOffset)
            guard let node = overlayPolygonNode(
                polygon,
                center: center,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: 0,
                materialPalette: materialPalette,
                opacity: effectiveOpacity,
                yOffset: effectiveYOffset
            ) else {
                continue
            }
            let group = layerGroupForCategory(polygon.layer, nodes: nodes)
            let baseY = overlayHeight(for: polygon.layer, board: board, boardThickness: boardThickness) + effectiveYOffset
            nodes.addExplodable(node: node, layer: polygon.layer, baseY: baseY)
            group.addChildNode(node)
        }

        for line in lines where !isExcludedFrom3DScene(line.layer) && !isPackageOrAssemblyLayer(line.layer) && !isSolderMaskLayer(line.layer) {
            if let layer = line.layer, let clipped = silkscreenClips[layer]?.object(line.id) {
                addClippedSilkscreen(
                    clipped, layer: layer, to: nodes, center: center, materialPalette: materialPalette, opacity: 0.82,
                    height: overlayHeight(for: layer, board: board, boardThickness: boardThickness) + overlayArtworkYOffset(for: layer, fallback: lineYOffset)
                )
                continue
            }
            let effectiveOpacity: CGFloat
            if let layer = line.layer {
                switch HorizontalBoardLayers.category(for: layer) {
                case .silkscreen: effectiveOpacity = 0.82
                case .solderMask: effectiveOpacity = 0.72
                default: effectiveOpacity = lineOpacity
                }
            } else {
                effectiveOpacity = lineOpacity
            }
            let effectiveYOffset = overlayArtworkYOffset(for: line.layer, fallback: lineYOffset)
            guard let node = overlayLineNode(
                line,
                center: center,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: 0,
                materialPalette: materialPalette,
                opacity: effectiveOpacity,
                yOffset: effectiveYOffset
            ) else {
                continue
            }
            let group = layerGroupForCategory(line.layer, nodes: nodes)
            let baseY = overlayHeight(for: line.layer, board: board, boardThickness: boardThickness) + effectiveYOffset
            nodes.addExplodable(node: node, layer: line.layer, baseY: baseY)
            group.addChildNode(node)
        }
    }

    /// Silkscreen clipped to the solder mask: what is left of an object, as
    /// thin fills in the silkscreen group, in place of its strokes.
    private static func addClippedSilkscreen(
        _ clipped: HorizontalClippedSilkscreenObject,
        layer: Int,
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        materialPalette: MaterialPalette,
        opacity: CGFloat,
        height: Double
    ) {
        let color = materialPalette.color(for: layer)
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.12)
        material.roughness.contents = 0.66
        material.isDoubleSided = true
        material.transparency = opacity
        // One flat sheet for the whole object. An extruded solid a few
        // microns thick z-fights its own back face once it is translucent,
        // and every triangle where the back face wins blends twice — the
        // triangulation shows through. A single layer of non-overlapping
        // triangles blends once everywhere, like the mask and copper slabs.
        guard let node = flatFragmentsNode(
            clipped.fragments,
            center: center,
            facingUp: !isBottomSideLayer(layer),
            material: material
        ) else {
            return
        }
        node.position = SCNVector3(0, horizonSceneScalar(height), 0)
        nodes.addExplodable(node: node, layer: layer, baseY: height)
        nodes.silkscreenGroup.addChildNode(node)
    }

    /// All of `fragments` as one flat mesh at y = 0: the top faces only, no
    /// thickness, so a translucent material covers the area exactly once.
    private static func flatFragmentsNode(
        _ fragments: [[[HorizontalPoint]]],
        center: HorizontalPoint,
        facingUp: Bool,
        material: SCNMaterial
    ) -> SCNNode? {
        let black = HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 1)
        let triangles = fragments.flatMap { HorizontalMetalTessellator.triangles(for: $0, color: black) }
        guard !triangles.isEmpty else {
            return nil
        }
        let normal = SCNVector3(0, horizonSceneScalar(facingUp ? 1.0 : -1.0), 0)
        var vertices = [SCNVector3]()
        var normals = [SCNVector3]()
        vertices.reserveCapacity(triangles.count * 3)
        normals.reserveCapacity(triangles.count * 3)
        func scenePoint(_ point: HorizontalPoint) -> SCNVector3 {
            SCNVector3(
                horizonSceneScalar((point.x - center.x) / unitsPerMillimeter),
                0,
                horizonSceneScalar(-(point.y - center.y) / unitsPerMillimeter)
            )
        }
        for triangle in triangles {
            let corners = facingUp ? [triangle.a, triangle.b, triangle.c] : [triangle.c, triangle.b, triangle.a]
            for corner in corners {
                vertices.append(scenePoint(corner))
                normals.append(normal)
            }
        }
        let indices = (0..<UInt32(vertices.count)).map { $0 }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [element]
        )
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func addPlanes(
        _ planes: [HorizontalPlane],
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        boardThickness: Double,
        materialPalette: MaterialPalette
    ) {
        let board = nodes.board
        for plane in planes where !isExcludedFrom3DScene(plane.layer) {
            for fragment in plane.renderFragments.prefix(maximumPlaneFragments) {
                guard let node = planeNode(
                    for: fragment,
                    layer: plane.layer,
                    center: center,
                    board: board,
                    boardThickness: boardThickness,
                    layerSeparation: 0,
                    isFallback: plane.fragments.isEmpty,
                    materialPalette: materialPalette
                ) else {
                    continue
                }
                node.name = "layer:\(plane.layer ?? -1)"
                let baseY = planeHeight(for: plane.layer, board: board, boardThickness: boardThickness)
                nodes.addExplodable(node: node, layer: plane.layer, baseY: baseY)
                nodes.planeGroup.addChildNode(node)
            }
        }
    }

    private static func planeNode(
        for fragment: HorizontalPlaneFragment,
        layer: Int?,
        center: HorizontalPoint,
        board: HorizontalBoard,
        boardThickness: Double,
        layerSeparation: Double,
        isFallback: Bool,
        materialPalette: MaterialPalette
    ) -> SCNNode? {
        guard let path = compoundPath(for: fragment.paths, center: center) else {
            return nil
        }

        let planeColor = materialPalette.color(for: layer)
        let material = SCNMaterial()
        horizonSceneConfigureCopperMaterial(material, color: planeColor)
        material.roughness.contents = isFallback ? 0.32 : 0.22
        material.writesToDepthBuffer = !isFallback

        let sideMaterial = SCNMaterial()
        horizonSceneConfigureCopperMaterial(sideMaterial, color: planeColor)
        sideMaterial.roughness.contents = isFallback ? 0.36 : 0.26
        sideMaterial.writesToDepthBuffer = !isFallback

        let shape = SCNShape(path: path, extrusionDepth: CGFloat(copperThickness(for: layer, board: board)))
        shape.materials = [material, sideMaterial, material]

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(
            0,
            horizonSceneScalar(planeHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)),
            0
        )
        node.eulerAngles.x = .pi / 2
        return node
    }

    private static func addCopperTraceGeometry(
        _ traces: [HorizontalSegment],
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        boardThickness: Double,
        materialPalette: MaterialPalette
    ) {
        let tracesByLayer = Dictionary(grouping: traces.filter { !isExcludedFrom3DScene($0.layer) }) {
            $0.layer ?? Int.min
        }

        for (layerKey, layerTraces) in tracesByLayer {
            let layer = layerKey == Int.min ? nil : layerKey
            let subjects = layerTraces.flatMap { traceClosedPaths($0) }
            guard !subjects.isEmpty else {
                continue
            }

            let cutouts = drillCutoutPaths(for: layer, board: nodes.board)
            let fragments = clippedSceneFragments(subjects: subjects, cutouts: cutouts)
            let pathsToRender: [[[HorizontalPoint]]]
            if fragments.isEmpty {
                guard cutouts.isEmpty else {
                    continue
                }
                pathsToRender = subjects.map { [$0] }
            } else {
                pathsToRender = fragments
            }

            for paths in pathsToRender {
                guard let node = copperTraceNode(
                    paths: paths,
                    layer: layer,
                    center: center,
                    board: nodes.board,
                    boardThickness: boardThickness,
                    layerSeparation: 0,
                    materialPalette: materialPalette
                ) else {
                    continue
                }
                node.name = "layer:\(layer ?? -1)"
                let baseY = copperHeight(for: layer, board: nodes.board, boardThickness: boardThickness)
                nodes.addExplodable(node: node, layer: layer, baseY: baseY)
                nodes.copperGroup.addChildNode(node)
            }
        }
    }

    private static func copperTraceNode(
        paths: [[HorizontalPoint]],
        layer: Int?,
        center: HorizontalPoint,
        board: HorizontalBoard,
        boardThickness: Double,
        layerSeparation: Double,
        materialPalette: MaterialPalette
    ) -> SCNNode? {
        guard let path = compoundPath(for: paths, center: center) else {
            return nil
        }

        let material = SCNMaterial()
        horizonSceneConfigureCopperMaterial(material, color: materialPalette.color(for: layer))

        let sideMaterial = SCNMaterial()
        horizonSceneConfigureCopperMaterial(sideMaterial, color: materialPalette.color(for: layer))
        sideMaterial.roughness.contents = 0.28

        let shape = SCNShape(path: path, extrusionDepth: CGFloat(copperThickness(for: layer, board: board)))
        shape.chamferRadius = 0.008
        shape.materials = [material, sideMaterial, material]

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(
            0,
            horizonSceneScalar(copperHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)),
            0
        )
        node.eulerAngles.x = .pi / 2
        return node
    }

    private static func addDecals(
        _ decals: [HorizontalBoardDecal],
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        boardThickness: Double,
        materialPalette: MaterialPalette
    ) {
        let board = nodes.board
        for decal in decals {
            for polygon in decal.polygons where !isExcludedFrom3DScene(polygon.layer) {
                let opacity: CGFloat = isSilkscreenLayer(polygon.layer) ? 1 : 0.58
                guard let node = overlayPolygonNode(
                    polygon,
                    center: center,
                    board: board,
                    boardThickness: boardThickness,
                    layerSeparation: 0,
                    materialPalette: materialPalette,
                    opacity: opacity,
                    yOffset: 0
                ) else {
                    continue
                }
                let baseY = overlayHeight(for: polygon.layer, board: board, boardThickness: boardThickness)
                nodes.addExplodable(node: node, layer: polygon.layer, baseY: baseY)
                nodes.decalGroup.addChildNode(node)
            }

            for line in decal.lines where !isExcludedFrom3DScene(line.layer) {
                let opacity: CGFloat = isSilkscreenLayer(line.layer) ? 1 : 0.62
                guard let node = overlayLineNode(
                    line,
                    center: center,
                    board: board,
                    boardThickness: boardThickness,
                    layerSeparation: 0,
                    materialPalette: materialPalette,
                    opacity: opacity,
                    yOffset: 0
                ) else {
                    continue
                }
                let baseY = overlayHeight(for: line.layer, board: board, boardThickness: boardThickness)
                nodes.addExplodable(node: node, layer: line.layer, baseY: baseY)
                nodes.decalGroup.addChildNode(node)
            }

            addCategorizedTexts(
                decal.texts,
                to: nodes,
                center: center,
                boardThickness: boardThickness,
                materialPalette: materialPalette
            )
        }
    }

    private static func addKeepouts(
        _ keepouts: [HorizontalKeepout],
        to group: SCNNode,
        center: HorizontalPoint,
        boardThickness: Double
    ) {
        for keepout in keepouts {
            guard let node = keepoutNode(
                keepout,
                center: center,
                boardThickness: boardThickness,
                layerSeparation: 0
            ) else {
                continue
            }
            group.addChildNode(node)
        }
    }

    private static func keepoutNode(
        _ keepout: HorizontalKeepout,
        center: HorizontalPoint,
        boardThickness: Double,
        layerSeparation: Double
    ) -> SCNNode? {
        guard let path = closedPath(for: keepout.polygon.renderVertices(arcPrecision: 32), center: center) else {
            return nil
        }

        let material = SCNMaterial()
        material.diffuse.contents = HorizontalDefaultTheme.nsColor(red: 1, green: 0, blue: 0).withAlphaComponent(0.32)
        material.emission.contents = HorizontalDefaultTheme.nsColor(red: 1, green: 0, blue: 0).withAlphaComponent(0.08)
        material.roughness.contents = 0.68
        material.isDoubleSided = true

        let shape = SCNShape(path: path, extrusionDepth: 0.01)
        shape.materials = [material, material, material]

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(
            0,
            horizonSceneScalar(
                overlayHeight(
                    for: keepout.polygon.layer,
                    boardThickness: boardThickness,
                    layerSeparation: layerSeparation
                ) + 0.015
            ),
            0
        )
        node.eulerAngles.x = .pi / 2
        return node
    }

    private static func addCategorizedTexts(
        _ texts: [HorizontalText],
        to nodes: BoardSceneNodes,
        center: HorizontalPoint,
        boardThickness: Double,
        materialPalette: MaterialPalette,
        silkscreenClips: [Int: HorizontalClippedSilkscreenLayer] = [:]
    ) {
        let board = nodes.board
        for text in texts where !text.text.isEmpty && !isExcludedFrom3DScene(text.layer) && !isPackageOrAssemblyLayer(text.layer) {
            if let layer = text.layer, let clipped = silkscreenClips[layer]?.object(text.id) {
                addClippedSilkscreen(
                    clipped, layer: layer, to: nodes, center: center, materialPalette: materialPalette, opacity: 0.82,
                    height: textOverlayHeight(for: layer, board: board, boardThickness: boardThickness)
                )
                continue
            }
            guard let node = textNode(
                text,
                center: center,
                materialPalette: materialPalette
            ) else {
                continue
            }
            let baseY = textOverlayHeight(for: text.layer, board: board, boardThickness: boardThickness)
            node.position.y = horizonSceneScalar(baseY)
            let group: SCNNode
            if let layer = text.layer, HorizontalBoardLayers.category(for: layer) == .silkscreen {
                group = nodes.silkscreenGroup
            } else {
                group = nodes.textGroup
            }
            nodes.addExplodable(node: node, layer: text.layer, baseY: baseY)
            group.addChildNode(node)
        }
    }

    private static func textNode(
        _ text: HorizontalText,
        center: HorizontalPoint,
        materialPalette: MaterialPalette
    ) -> SCNNode? {
        let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
        guard !segments.isEmpty else {
            return nil
        }

        let material = SCNMaterial()
        material.diffuse.contents = materialPalette.color(for: text.layer).withAlphaComponent(0.82)
        material.emission.contents = materialPalette.color(for: text.layer).withAlphaComponent(0.14)
        material.isDoubleSided = true
        material.roughness.contents = 0.64

        let parent = SCNNode()
        let strokeWidth = max(text.width, text.size * 0.035, 35_000)
        for (index, segment) in segments.enumerated() {
            let line = HorizontalSegment(
                id: "\(text.id)/outline/\(index)",
                from: segment.0,
                to: segment.1,
                width: strokeWidth,
                layer: text.layer
            )
            if let node = outlineTextSegmentNode(
                line,
                center: center,
                material: material
            ) {
                parent.addChildNode(node)
            }
        }

        return parent.childNodes.isEmpty ? nil : parent
    }

    private static func overlayPolygonNode(
        _ polygon: HorizontalPolygon,
        center: HorizontalPoint,
        board: HorizontalBoard,
        boardThickness: Double,
        layerSeparation: Double,
        materialPalette: MaterialPalette,
        opacity: CGFloat,
        yOffset: Double
    ) -> SCNNode? {
        let contours = bridgedClosedSceneContours(from: polygon.renderVertices(arcPrecision: 32))
        guard !contours.isEmpty else {
            return nil
        }

        let color = materialPalette.color(for: polygon.layer)
        let material = SCNMaterial()
        if let layer = polygon.layer, HorizontalBoardLayers.category(for: layer) == .paste {
            horizonSceneConfigurePasteMaterial(material, color: color)
        } else {
            material.diffuse.contents = color
            material.emission.contents = color.withAlphaComponent(0.16)
            material.roughness.contents = 0.62
            material.isDoubleSided = true
            material.transparency = opacity
        }

        let extrusionDirection: Double = polygon.layer.map { isBottomSideLayer($0) } == true ? -1 : 1
        if let node = filledPolygonNode(
            contours: contours,
            center: center,
            thickness: 0.012,
            extrusionDirection: extrusionDirection,
            material: material
        ) {
            node.position = SCNVector3(
                0,
                horizonSceneScalar(
                    overlayHeight(for: polygon.layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation) + yOffset
                ),
                0
            )
            return node
        }

        guard let path = closedPath(for: polygon.renderVertices(arcPrecision: 32), center: center) else {
            return nil
        }

        let shape = SCNShape(path: path, extrusionDepth: 0.012)
        shape.materials = [material, material, material]

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(
            0,
            horizonSceneScalar(
                overlayHeight(for: polygon.layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation) + yOffset
            ),
            0
        )
        node.eulerAngles.x = .pi / 2
        return node
    }

    /// A slab's footprint as clipper fragments (each an outer contour then its
    /// holes), plus the grid lines the footprint was tiled along: an edge on
    /// one of those is a seam between tiles, not a wall.
    private struct SlabFragments {
        var fragments: [[[HorizontalPoint]]]
        var seamXs: [Double] = []
        var seamYs: [Double] = []

        var isEmpty: Bool { fragments.isEmpty }
    }

    /// A slab's mesh before it has a thickness: oriented contours and their
    /// triangulation, computed once and extruded for every slab that shares
    /// the footprint (each dielectric layer of a multi-layer board).
    private struct ExtrudedMeshTemplate {
        struct Fragment {
            var contours: [[HorizontalPoint]]
            var triangles: [(HorizontalPoint, HorizontalPoint, HorizontalPoint)]
        }

        var fragments: [Fragment]
        var seamXs: [Double]
        var seamYs: [Double]

        var isEmpty: Bool { fragments.allSatisfy { $0.triangles.isEmpty } }

        init(_ slab: SlabFragments) {
            let black = HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 1)
            seamXs = slab.seamXs
            seamYs = slab.seamYs
            fragments = slab.fragments.compactMap { fragment in
                var contours = fragment.map(cleanedClosedScenePoints).filter { $0.count >= 3 }
                guard !contours.isEmpty else {
                    return nil
                }
                // Outer counter-clockwise, holes clockwise: the wall normals
                // and windings assume material lies to the left of every edge.
                for index in contours.indices {
                    let clockwise = signedArea(of: contours[index]) < 0
                    if (index == 0) == clockwise {
                        contours[index].reverse()
                    }
                }
                let triangles = HorizontalMetalTessellator.fragmentTriangles(contours, color: black).map { triangle in
                    signedArea(of: [triangle.a, triangle.b, triangle.c]) < 0
                        ? (triangle.c, triangle.b, triangle.a)
                        : (triangle.a, triangle.b, triangle.c)
                }
                return Fragment(contours: contours, triangles: triangles)
            }
        }
    }

    /// `template` as one extruded solid: top and bottom faces from its
    /// triangulation, a wall along every contour edge that is not a tile
    /// seam. Built here rather than through `SCNShape`, whose tessellation of
    /// a path with hundreds of subpaths — a board outline with its drills, a
    /// mask with its openings — takes tens of seconds. The node's origin sits
    /// mid-thickness so explode moves it as a slab.
    private static func extrudedFragmentsNode(
        _ template: ExtrudedMeshTemplate,
        center: HorizontalPoint,
        thickness: Double,
        topY: Double,
        faceMaterial: SCNMaterial,
        sideMaterial: SCNMaterial
    ) -> SCNNode? {
        let half = thickness / 2
        var vertices = [SCNVector3]()
        var normals = [SCNVector3]()
        var faceIndices = [UInt32]()
        var wallIndices = [UInt32]()

        func scenePoint(_ point: HorizontalPoint, y: Double) -> SCNVector3 {
            SCNVector3(
                horizonSceneScalar((point.x - center.x) / unitsPerMillimeter),
                horizonSceneScalar(y),
                horizonSceneScalar(-(point.y - center.y) / unitsPerMillimeter)
            )
        }
        func append(_ point: HorizontalPoint, y: Double, normal: SCNVector3, to indices: inout [UInt32]) {
            vertices.append(scenePoint(point, y: y))
            normals.append(normal)
            indices.append(UInt32(vertices.count - 1))
        }
        func isSeam(_ first: HorizontalPoint, _ second: HorizontalPoint) -> Bool {
            let tolerance = 1.0
            if abs(first.x - second.x) <= tolerance,
               template.seamXs.contains(where: { abs($0 - first.x) <= tolerance }) {
                return true
            }
            if abs(first.y - second.y) <= tolerance,
               template.seamYs.contains(where: { abs($0 - first.y) <= tolerance }) {
                return true
            }
            return false
        }

        let up = SCNVector3(0, 1, 0)
        let down = SCNVector3(0, -1, 0)
        for fragment in template.fragments {
            for (a, b, c) in fragment.triangles {
                append(a, y: half, normal: up, to: &faceIndices)
                append(b, y: half, normal: up, to: &faceIndices)
                append(c, y: half, normal: up, to: &faceIndices)
                append(c, y: -half, normal: down, to: &faceIndices)
                append(b, y: -half, normal: down, to: &faceIndices)
                append(a, y: -half, normal: down, to: &faceIndices)
            }
            for contour in fragment.contours {
                for index in contour.indices {
                    let first = contour[index]
                    let second = contour[(index + 1) % contour.count]
                    if isSeam(first, second) {
                        continue
                    }
                    let dx = second.x - first.x
                    let dy = second.y - first.y
                    let length = max((dx * dx + dy * dy).squareRoot(), 0.000001)
                    // Outward for a counter-clockwise outer (and into a
                    // clockwise hole), in scene axes: Horizon y is scene -z.
                    let normal = SCNVector3(horizonSceneScalar(dy / length), 0, horizonSceneScalar(dx / length))
                    append(first, y: -half, normal: normal, to: &wallIndices)
                    append(second, y: -half, normal: normal, to: &wallIndices)
                    append(second, y: half, normal: normal, to: &wallIndices)
                    append(first, y: -half, normal: normal, to: &wallIndices)
                    append(second, y: half, normal: normal, to: &wallIndices)
                    append(first, y: half, normal: normal, to: &wallIndices)
                }
            }
        }
        guard !faceIndices.isEmpty else {
            return nil
        }

        func element(_ indices: [UInt32]) -> SCNGeometryElement {
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
        }
        var elements = [element(faceIndices)]
        if !wallIndices.isEmpty {
            elements.append(element(wallIndices))
        }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: elements
        )
        geometry.materials = wallIndices.isEmpty ? [faceMaterial] : [faceMaterial, sideMaterial]
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(0, horizonSceneScalar(topY - half), 0)
        return node
    }

    /// Tiles a slab is cut into before triangulation. Earcut bridges every
    /// hole to the outer ring by scanning it, so one polygon with a thousand
    /// drills costs seconds; tiles of a few holes each cost milliseconds
    /// in total. The clipper places the same intersection points on both
    /// sides of a tile edge, so neighbouring meshes meet without cracks.
    private static let slabTileSize = 8.0 * unitsPerMillimeter
    private static let untiledCutoutLimit = 48

    /// `outline` minus `cutouts`: the outline's own keyhole-bridged holes
    /// count as cutouts too. The outline alone when nothing cuts it.
    private static func outlineFragments(
        for outline: HorizontalPolygon,
        cutouts: [[HorizontalPoint]]
    ) -> SlabFragments {
        let contours = bridgedClosedSceneContours(from: outline.renderVertices(arcPrecision: 32))
        guard let outer = contours.first else {
            return SlabFragments(fragments: [])
        }
        let bounds = HorizontalRect(points: outer)
        let relevant = cutouts.filter { cutout in cutout.contains { bounds.contains($0) } }
        let allCutouts = Array(contours.dropFirst()) + relevant
        guard !allCutouts.isEmpty else {
            return SlabFragments(fragments: [contours])
        }
        if allCutouts.count <= untiledCutoutLimit {
            let fragments = clippedSceneFragments(subjects: [outer], cutouts: allCutouts)
            return SlabFragments(fragments: fragments.isEmpty ? [contours] : fragments)
        }

        let columns = max(Int((bounds.width / slabTileSize).rounded(.up)), 1)
        let rows = max(Int((bounds.height / slabTileSize).rounded(.up)), 1)
        let xs = (0...columns).map { bounds.minX + bounds.width * Double($0) / Double(columns) }
        let ys = (0...rows).map { bounds.minY + bounds.height * Double($0) / Double(rows) }
        let cutoutBounds = allCutouts.map { HorizontalRect(points: $0) }
        var fragments = [[[HorizontalPoint]]]()
        for row in 0..<rows {
            for column in 0..<columns {
                let tile = [
                    HorizontalPoint(x: xs[column], y: ys[row]),
                    HorizontalPoint(x: xs[column + 1], y: ys[row]),
                    HorizontalPoint(x: xs[column + 1], y: ys[row + 1]),
                    HorizontalPoint(x: xs[column], y: ys[row + 1]),
                ]
                let tileBounds = HorizontalRect(points: tile)
                // What the tile holds outside the outline is cut away too.
                let exterior = clippedSceneFragments(subjects: [tile], cutouts: [outer]).compactMap(\.first)
                let tileCutouts = exterior + zip(allCutouts, cutoutBounds)
                    .filter { $0.1.intersects(tileBounds) }
                    .map(\.0)
                if tileCutouts.isEmpty {
                    fragments.append([tile])
                } else {
                    fragments.append(contentsOf: clippedSceneFragments(subjects: [tile], cutouts: tileCutouts))
                }
            }
        }
        return SlabFragments(
            fragments: fragments,
            seamXs: Array(xs.dropFirst().dropLast()),
            seamYs: Array(ys.dropFirst().dropLast())
        )
    }

    private static func filledPolygonNode(
        contours: [[HorizontalPoint]],
        center: HorizontalPoint,
        thickness: Double,
        extrusionDirection: Double,
        material: SCNMaterial
    ) -> SCNNode? {
        let triangles = HorizontalMetalTessellator.triangles(
            for: contours,
            color: HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 1)
        )
        guard !triangles.isEmpty, thickness > 0 else {
            return nil
        }

        var vertices = [SCNVector3]()
        var normals = [SCNVector3]()
        var indices = [UInt32]()
        let contourVertexCount = contours.reduce(0) { $0 + $1.count }
        vertices.reserveCapacity(triangles.count * 6 + contourVertexCount * 6)
        normals.reserveCapacity(triangles.count * 6 + contourVertexCount * 6)
        indices.reserveCapacity(triangles.count * 6 + contourVertexCount * 6)

        func scenePoint(_ point: HorizontalPoint, y: Double) -> SCNVector3 {
            SCNVector3(
                horizonSceneScalar((point.x - center.x) / unitsPerMillimeter),
                horizonSceneScalar(y),
                horizonSceneScalar(-(point.y - center.y) / unitsPerMillimeter)
            )
        }

        func append(_ point: HorizontalPoint, y: Double, normal: SCNVector3) {
            vertices.append(
                scenePoint(point, y: y)
            )
            normals.append(normal)
            indices.append(UInt32(vertices.count - 1))
        }

        let outwardSign: Double = extrusionDirection < 0 ? -1 : 1
        let outerY = thickness * outwardSign
        let baseY = 0.0
        let outerNormal = SCNVector3(0, horizonSceneScalar(outwardSign), 0)
        let baseNormal = SCNVector3(0, horizonSceneScalar(-outwardSign), 0)
        for triangle in triangles {
            append(triangle.a, y: outerY, normal: outerNormal)
            append(triangle.b, y: outerY, normal: outerNormal)
            append(triangle.c, y: outerY, normal: outerNormal)

            append(triangle.c, y: baseY, normal: baseNormal)
            append(triangle.b, y: baseY, normal: baseNormal)
            append(triangle.a, y: baseY, normal: baseNormal)
        }

        for contour in contours {
            let contour = cleanedClosedScenePoints(contour)
            guard contour.count >= 3 else {
                continue
            }

            for index in contour.indices {
                let nextIndex = contour.index(after: index) == contour.endIndex ? contour.startIndex : contour.index(after: index)
                let first = contour[index]
                let second = contour[nextIndex]
                let firstScene = scenePoint(first, y: 0)
                let secondScene = scenePoint(second, y: 0)
                let dx = secondScene.x - firstScene.x
                let dz = secondScene.z - firstScene.z
                let length = max(sqrt(dx * dx + dz * dz), 0.000001)
                let normal = SCNVector3(dz / length, 0, -dx / length)

                append(first, y: baseY, normal: normal)
                append(second, y: baseY, normal: normal)
                append(second, y: outerY, normal: normal)

                append(first, y: baseY, normal: normal)
                append(second, y: outerY, normal: normal)
                append(first, y: outerY, normal: normal)
            }
        }

        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals)
            ],
            elements: [element]
        )
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func overlayLineNode(
        _ line: HorizontalSegment,
        center: HorizontalPoint,
        board: HorizontalBoard,
        boardThickness: Double,
        layerSeparation: Double,
        materialPalette: MaterialPalette,
        opacity: CGFloat,
        yOffset: Double
    ) -> SCNNode? {
        guard let path = trackPath(line, center: center) else {
            return nil
        }

        let color = materialPalette.color(for: line.layer)
        let material = SCNMaterial()
        if let layer = line.layer, HorizontalBoardLayers.category(for: layer) == .paste {
            horizonSceneConfigurePasteMaterial(material, color: color)
        } else {
            material.diffuse.contents = color
            material.emission.contents = color.withAlphaComponent(0.12)
            material.roughness.contents = 0.66
            material.isDoubleSided = true
            material.transparency = opacity
        }

        let shape = SCNShape(path: path, extrusionDepth: 0.012)
        shape.materials = [material, material, material]

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(
            0,
            horizonSceneScalar(
                overlayHeight(for: line.layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation) + yOffset
            ),
            0
        )
        node.eulerAngles.x = .pi / 2
        return node
    }

    private static func outlineTextSegmentNode(
        _ line: HorizontalSegment,
        center: HorizontalPoint,
        material: SCNMaterial
    ) -> SCNNode? {
        guard let path = trackPath(line, center: center, minimumWidthMillimeters: 0.035) else {
            return nil
        }

        let shape = SCNShape(path: path, extrusionDepth: 0.006)
        shape.materials = [material, material, material]

        let node = SCNNode(geometry: shape)
        node.eulerAngles.x = .pi / 2
        return node
    }

    private static func addConnectionLines(
        _ connectionLines: [HorizontalSegment],
        to group: SCNNode,
        center: HorizontalPoint,
        color: HorizontalPlatformColor
    ) {
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(0.62)
        material.emission.contents = color.withAlphaComponent(0.16)
        material.roughness.contents = 0.5

        var dashCount = 0
        for connectionLine in connectionLines {
            for node in connectionLineNodes(connectionLine, center: center, material: material) {
                guard dashCount < maximumConnectionLineDashes else {
                    return
                }
                group.addChildNode(node)
                dashCount += 1
            }
        }
    }

    private static func connectionLineNodes(
        _ connectionLine: HorizontalSegment,
        center: HorizontalPoint,
        material: SCNMaterial
    ) -> [SCNNode] {
        let start = scenePosition(connectionLine.from, center: center, y: 1.08)
        let end = scenePosition(connectionLine.to, center: center, y: 1.08)
        let vector = SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
        let length = vectorLength(vector)
        guard length > 0.05 else {
            return []
        }

        let direction = SCNVector3(vector.x / length, vector.y / length, vector.z / length)
        let dashLength = min(max(length * 0.12, 1.2), 3.2)
        let gapLength = dashLength * 0.72
        let step = dashLength + gapLength
        var nodes = [SCNNode]()
        var offset: HorizontalSceneScalar = 0

        while offset < length {
            let segmentLength = min(dashLength, length - offset)
            let segmentStart = pointAlong(start, direction: direction, distance: offset)
            let segmentEnd = pointAlong(start, direction: direction, distance: offset + segmentLength)
            if let node = cylinderNode(from: segmentStart, to: segmentEnd, radius: 0.025, material: material) {
                nodes.append(node)
            }
            offset += step
        }

        return nodes
    }

    private static func cylinderNode(
        from start: SCNVector3,
        to end: SCNVector3,
        radius: CGFloat,
        material: SCNMaterial
    ) -> SCNNode? {
        let vector = SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
        let length = vectorLength(vector)
        guard length > 0.01 else {
            return nil
        }

        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        cylinder.materials = [material]

        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3(
            (start.x + end.x) / 2,
            (start.y + end.y) / 2,
            (start.z + end.z) / 2
        )
        orientCylinder(node, along: vector)
        return node
    }

    private static func orientCylinder(_ node: SCNNode, along vector: SCNVector3) {
        let length = vectorLength(vector)
        guard length > 0 else {
            return
        }

        let direction = SCNVector3(vector.x / length, vector.y / length, vector.z / length)
        let yAxis = SCNVector3(0, 1, 0)
        let axis = cross(yAxis, direction)
        let axisLength = vectorLength(axis)
        let dotProduct = min(max(dot(yAxis, direction), -1), 1)

        if axisLength < 0.0001 {
            if dotProduct < 0 {
                node.rotation = SCNVector4(1, 0, 0, horizonSceneScalar(Double.pi))
            }
            return
        }

        node.rotation = SCNVector4(
            axis.x / axisLength,
            axis.y / axisLength,
            axis.z / axisLength,
            acos(dotProduct)
        )
    }

    private static func addLighting(to scene: SCNScene, width: Double, depth: Double) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 170
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        func directionalLight(intensity: CGFloat, position: SCNVector3, euler: SCNVector3) -> SCNNode {
            let light = SCNLight()
            light.type = .directional
            light.intensity = intensity
            light.castsShadow = true
            light.shadowColor = HorizontalPlatformColor.black.withAlphaComponent(0.24)
            light.shadowRadius = 4
            light.shadowSampleCount = 8

            let node = SCNNode()
            node.light = light
            node.position = position
            node.eulerAngles = euler
            return node
        }

        let maxDimension = max(width, depth)
        scene.rootNode.addChildNode(directionalLight(
            intensity: 1_150,
            position: SCNVector3(
                horizonSceneScalar(width * 0.35),
                horizonSceneScalar(maxDimension * 1.15),
                horizonSceneScalar(depth * 0.32)
            ),
            euler: SCNVector3(
                -horizonSceneScalar(Double.pi) / 3.2,
                horizonSceneScalar(Double.pi) / 4.5,
                0
            )
        ))

        scene.rootNode.addChildNode(directionalLight(
            intensity: 260,
            position: SCNVector3(
                -horizonSceneScalar(width * 0.8),
                horizonSceneScalar(maxDimension * 0.55),
                -horizonSceneScalar(depth * 0.65)
            ),
            euler: SCNVector3(
                -horizonSceneScalar(Double.pi) / 5,
                -horizonSceneScalar(Double.pi) / 3,
                0
            )
        ))

        scene.rootNode.addChildNode(directionalLight(
            intensity: 380,
            position: SCNVector3(
                0,
                horizonSceneScalar(maxDimension * 0.85),
                -horizonSceneScalar(depth)
            ),
            euler: SCNVector3(
                -horizonSceneScalar(Double.pi) / 4,
                horizonSceneScalar(Double.pi),
                0
            )
        ))
    }

    private static func addBoardOriginAxes(
        to group: SCNNode,
        center: HorizontalPoint,
        width: Double,
        depth: Double
    ) {
        let y = boardTopHeight + 0.16
        let length = min(max(width, depth) * 0.08, 6)
        let origin = scenePosition(.zero, center: center, y: y)
        let axisLength = horizonSceneScalar(length)
        let xEnd = SCNVector3(origin.x + axisLength, origin.y, origin.z)
        let yEnd = SCNVector3(origin.x, origin.y, origin.z - axisLength)

        let redMaterial = SCNMaterial()
        redMaterial.diffuse.contents = HorizontalDefaultTheme.nsColor(red: 1, green: 0, blue: 0).withAlphaComponent(0.7)
        redMaterial.emission.contents = HorizontalDefaultTheme.nsColor(red: 1, green: 0, blue: 0).withAlphaComponent(0.12)

        let greenMaterial = SCNMaterial()
        greenMaterial.diffuse.contents = HorizontalDefaultTheme.nsColor(red: 0, green: 1, blue: 0).withAlphaComponent(0.7)
        greenMaterial.emission.contents = HorizontalDefaultTheme.nsColor(red: 0, green: 1, blue: 0).withAlphaComponent(0.12)

        if let xAxis = cylinderNode(from: origin, to: xEnd, radius: 0.018, material: redMaterial) {
            group.addChildNode(xAxis)
        }
        if let yAxis = cylinderNode(from: origin, to: yEnd, radius: 0.018, material: greenMaterial) {
            group.addChildNode(yAxis)
        }
        group.addChildNode(axisLabelNode("X", position: xEnd, color: HorizontalDefaultTheme.nsColor(red: 1, green: 0, blue: 0)))
        group.addChildNode(axisLabelNode("Y", position: yEnd, color: HorizontalDefaultTheme.nsColor(red: 0, green: 1, blue: 0)))
    }

    private static func addOrientationAxes(to group: SCNNode, width: Double, depth: Double) {
        let origin = SCNVector3(
            horizonSceneScalar(-width / 2 + 1.2),
            horizonSceneScalar(boardTopHeight + 0.9),
            horizonSceneScalar(-depth / 2 + 1.2)
        )
        let length = horizonSceneScalar(1.3)

        let axes: [(String, SCNVector3, HorizontalPlatformColor)] = [
            ("X", SCNVector3(origin.x + length, origin.y, origin.z), HorizontalDefaultTheme.nsColor(red: 1, green: 0, blue: 0)),
            ("Y", SCNVector3(origin.x, origin.y + length, origin.z), HorizontalDefaultTheme.nsColor(red: 0, green: 1, blue: 0)),
            ("Z", SCNVector3(origin.x, origin.y, origin.z + length), HorizontalDefaultTheme.nsColor(red: 0, green: 78.0 / 255.0, blue: 208.0 / 255.0))
        ]

        for (label, end, color) in axes {
            let material = SCNMaterial()
            material.diffuse.contents = color.withAlphaComponent(0.76)
            material.emission.contents = color.withAlphaComponent(0.12)
            if let node = cylinderNode(from: origin, to: end, radius: 0.025, material: material) {
                group.addChildNode(node)
            }
            group.addChildNode(axisLabelNode(label, position: end, color: color))
        }
    }

    private static func axisLabelNode(_ label: String, position: SCNVector3, color: HorizontalPlatformColor) -> SCNNode {
        let text = SCNText(string: label, extrusionDepth: 0.01)
        #if canImport(AppKit)
        text.font = NSFont.systemFont(ofSize: 1, weight: .bold)
        #else
        text.font = UIFont.systemFont(ofSize: 1, weight: .bold)
        #endif
        text.flatness = 0.2
        text.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.82)
        text.firstMaterial?.emission.contents = color.withAlphaComponent(0.18)

        let node = SCNNode(geometry: text)
        let bounds = text.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(
            (bounds.max.x + bounds.min.x) / 2,
            (bounds.max.y + bounds.min.y) / 2,
            0
        )
        node.scale = SCNVector3(0.32, 0.32, 0.32)
        node.position = SCNVector3(position.x + 0.16, position.y + 0.16, position.z + 0.16)
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    private static func addCamera(
        to scene: SCNScene,
        width: Double,
        depth: Double,
        projection: HorizontalBoardSceneProjection
    ) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.usesOrthographicProjection = projection == .orthogonal
        camera.orthographicScale = max(width, depth) * 1.6
        camera.zNear = 0.1
        camera.zFar = max(width, depth) * 8

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let distance = max(max(width, depth) * 2.4, 18)
        let axisDistance = horizonSceneScalar(distance / sqrt(3.0))
        cameraNode.position = SCNVector3(-axisDistance, axisDistance, axisDistance)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        return cameraNode
    }

    private static func trackNode(
        _ track: HorizontalSegment,
        center: HorizontalPoint,
        materialPalette: MaterialPalette,
        board: HorizontalBoard,
        boardThickness: Double,
        layerSeparation: Double
    ) -> SCNNode? {
        guard let path = trackPath(track, center: center) else {
            return nil
        }

        let material = SCNMaterial()
        horizonSceneConfigureCopperMaterial(material, color: materialPalette.color(for: track.layer))

        let sideMaterial = SCNMaterial()
        horizonSceneConfigureCopperMaterial(sideMaterial, color: materialPalette.color(for: track.layer))
        sideMaterial.roughness.contents = 0.28

        let shape = SCNShape(path: path, extrusionDepth: CGFloat(copperThickness(for: track.layer, board: board)))
        shape.chamferRadius = 0.008
        shape.materials = [material, sideMaterial, material]

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(
            0,
            horizonSceneScalar(copperHeight(for: track.layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)),
            0
        )
        node.eulerAngles.x = .pi / 2
        return node
    }

    private static func trackPath(
        _ track: HorizontalSegment,
        center: HorizontalPoint,
        minimumWidthMillimeters: CGFloat = 0.18
    ) -> HorizontalPlatformBezierPath? {
        let radius = max(track.width / unitsPerMillimeter, minimumWidthMillimeters) / 2
        guard radius.isFinite, radius > 0 else {
            return nil
        }

        if track.center != nil {
            let points = cleanedOpenScenePoints(track.pathPoints).map { pathPoint($0, center: center) }
            guard points.count >= 2 else {
                return nil
            }

            let path = HorizontalPlatformBezierPath()
            var hasSegment = false
            for pair in zip(points, points.dropFirst()) {
                hasSegment = appendTrackCapsule(from: pair.0, to: pair.1, radius: radius, to: path) || hasSegment
            }
            return hasSegment ? path : nil
        }

        let from = pathPoint(track.from, center: center)
        let to = pathPoint(track.to, center: center)
        let path = HorizontalPlatformBezierPath()
        return appendTrackCapsule(from: from, to: to, radius: radius, to: path) ? path : nil
    }

    private static func traceClosedPaths(
        _ trace: HorizontalSegment,
        minimumWidthMillimeters: Double = 0.18
    ) -> [[HorizontalPoint]] {
        let radius = max(trace.width, minimumWidthMillimeters * unitsPerMillimeter) / 2
        guard radius.isFinite, radius > 0 else {
            return []
        }

        let points = cleanedOpenScenePoints(trace.pathPoints)
        guard points.count >= 2 else {
            return []
        }

        return zip(points, points.dropFirst()).compactMap { pair in
            traceCapsulePoints(from: pair.0, to: pair.1, radius: radius)
        }
    }

    private static func traceCapsulePoints(
        from: HorizontalPoint,
        to: HorizontalPoint,
        radius: Double,
        segments: Int = 16
    ) -> [HorizontalPoint]? {
        guard radius.isFinite,
              from.x.isFinite,
              from.y.isFinite,
              to.x.isFinite,
              to.y.isFinite else {
            return nil
        }

        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 10 else {
            return nil
        }

        let unitX = dx / length
        let unitY = dy / length
        let normalX = -unitY
        let normalY = unitX
        let arcSegments = max(segments, 8)
        var points = [HorizontalPoint]()
        points.reserveCapacity(arcSegments * 2 + 2)
        points.append(HorizontalPoint(
            x: to.x + normalX * radius,
            y: to.y + normalY * radius
        ))

        for index in 1...arcSegments {
            let angle = Double(index) / Double(arcSegments) * Double.pi
            points.append(HorizontalPoint(
                x: to.x + (normalX * cos(angle) + unitX * sin(angle)) * radius,
                y: to.y + (normalY * cos(angle) + unitY * sin(angle)) * radius
            ))
        }

        for index in 0...arcSegments {
            let angle = Double.pi + Double(index) / Double(arcSegments) * Double.pi
            points.append(HorizontalPoint(
                x: from.x + (normalX * cos(angle) + unitX * sin(angle)) * radius,
                y: from.y + (normalY * cos(angle) + unitY * sin(angle)) * radius
            ))
        }

        return cleanedClosedScenePoints(points)
    }

    private static func drillCutoutPaths(for layer: Int?, board: HorizontalBoard) -> [[HorizontalPoint]] {
        let viaLayersByHoleID = Dictionary(
            uniqueKeysWithValues: board.vias.map { via in
                ("\(via.id)/hole", Set(via.connectedLayers.filter(HorizontalBoardLayers.isCopper)))
            }
        )

        func holeOverlapsLayer(_ hole: HorizontalHole) -> Bool {
            guard let layer else {
                return true
            }
            if let viaLayers = viaLayersByHoleID[hole.id], !viaLayers.isEmpty {
                return viaLayers.contains(layer)
            }
            return HorizontalBoardLayers.isCopper(layer)
        }

        return (board.holes + board.viaHoles + board.packageHoles).compactMap { hole in
            guard holeOverlapsLayer(hole) else {
                return nil
            }
            // 24 segments: round enough for a drill seen in 3D, and every
            // point costs in the clipper and the earcut alike.
            let points = cleanedClosedScenePoints(hole.outlinePoints(precision: 24))
            return points.count >= 3 ? points : nil
        }
    }

    private static func clippedSceneFragments(
        subjects: [[HorizontalPoint]],
        cutouts: [[HorizontalPoint]]
    ) -> [[[HorizontalPoint]]] {
        guard !subjects.isEmpty else {
            return []
        }

        let rawFragments = BoardSceneClipperPathStorage.withPaths(subjects, cutouts) { subjectStorage, cutoutStorage in
            HorizontalClipperBuildPlaneFill(
                subjectStorage.pointer,
                Int32(subjectStorage.count),
                cutoutStorage.pointer,
                Int32(cutoutStorage.count),
                0,
                1_000,
                0
            )
        }
        defer {
            HorizontalClipperFreeFragments(rawFragments)
        }

        guard let fragmentPointer = rawFragments.fragments,
              rawFragments.count > 0 else {
            return []
        }

        return (0..<Int(rawFragments.count)).compactMap { fragmentIndex in
            let fragment = fragmentPointer[fragmentIndex]
            guard let pathPointer = fragment.paths,
                  fragment.count > 0 else {
                return nil
            }

            let paths = (0..<Int(fragment.count)).compactMap { pathIndex -> [HorizontalPoint]? in
                let path = pathPointer[pathIndex]
                guard let pointPointer = path.points,
                      path.count >= 3 else {
                    return nil
                }

                let points = (0..<Int(path.count)).map { pointIndex in
                    let point = pointPointer[pointIndex]
                    return HorizontalPoint(x: point.x, y: point.y)
                }
                let cleaned = cleanedClosedScenePoints(points)
                return cleaned.count >= 3 ? cleaned : nil
            }
            return paths.isEmpty ? nil : paths
        }
    }

    @discardableResult
    private static func appendTrackCapsule(
        from: CGPoint,
        to: CGPoint,
        radius: CGFloat,
        to path: HorizontalPlatformBezierPath
    ) -> Bool {
        guard radius.isFinite,
              from.x.isFinite,
              from.y.isFinite,
              to.x.isFinite,
              to.y.isFinite else {
            return false
        }

        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 0.01 else {
            return false
        }

        let unitX = dx / length
        let unitY = dy / length
        let normalX = -unitY
        let normalY = unitX
        let segments = 10

        path.move(to: CGPoint(
            x: to.x + normalX * radius,
            y: to.y + normalY * radius
        ))

        for index in 1...segments {
            let angle = Double(index) / Double(segments) * Double.pi
            let x = to.x + (normalX * cos(angle) + unitX * sin(angle)) * radius
            let y = to.y + (normalY * cos(angle) + unitY * sin(angle)) * radius
            path.horizonLine(to: CGPoint(x: x, y: y))
        }

        for index in 0...segments {
            let angle = Double.pi + Double(index) / Double(segments) * Double.pi
            let x = from.x + (normalX * cos(angle) + unitX * sin(angle)) * radius
            let y = from.y + (normalY * cos(angle) + unitY * sin(angle)) * radius
            path.horizonLine(to: CGPoint(x: x, y: y))
        }

        path.close()
        return true
    }

    private static func padNode(
        _ pad: HorizontalPadOutlineFragment,
        paths: [[HorizontalPoint]]? = nil,
        center: HorizontalPoint,
        board: HorizontalBoard,
        boardThickness: Double,
        layerSeparation: Double,
        materialPalette: MaterialPalette
    ) -> SCNNode? {
        guard let path = compoundPath(for: paths ?? pad.paths, center: center) else {
            return nil
        }

        let material = SCNMaterial()
        let padColor = materialPalette.padColor(for: pad.layer)
        if let layer = pad.layer, HorizontalBoardLayers.category(for: layer) == .paste {
            horizonSceneConfigurePasteMaterial(material, color: padColor)
        } else if let layer = pad.layer, HorizontalBoardLayers.isCopper(layer) {
            horizonSceneConfigureCopperMaterial(material, color: padColor)
        } else {
            material.diffuse.contents = padColor
            material.roughness.contents = 0.55
            material.transparency = 1
            material.isDoubleSided = true
        }

        let sideMaterial = SCNMaterial()
        if let layer = pad.layer, HorizontalBoardLayers.category(for: layer) == .paste {
            horizonSceneConfigurePasteMaterial(sideMaterial, color: padColor)
        } else if let layer = pad.layer, HorizontalBoardLayers.isCopper(layer) {
            horizonSceneConfigureCopperMaterial(sideMaterial, color: padColor)
            sideMaterial.roughness.contents = 0.28
        } else {
            sideMaterial.diffuse.contents = padColor
            sideMaterial.roughness.contents = 0.65
            sideMaterial.transparency = 1
            sideMaterial.isDoubleSided = true
        }

        let shape = SCNShape(path: path, extrusionDepth: padExtrusionDepth(for: pad.layer, board: board))
        shape.chamferRadius = 0.01
        shape.materials = [material, sideMaterial, material]

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(
            0,
                horizonSceneScalar(padTopSurfaceHeight(for: pad.layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)),
                0
        )
        node.eulerAngles.x = .pi / 2
        return node
    }

    private static func boardOutlinePath(for polygon: HorizontalPolygon, center: HorizontalPoint) -> HorizontalPlatformBezierPath? {
        closedPath(for: polygon.renderVertices(arcPrecision: 32), center: center)
    }

    /// The outline with the drill cutouts (and the outline's own bridged
    /// holes) clipped out of it, as an even-odd compound path. Without
    /// cutouts this is the plain outline path.
    private static func closedPath(for vertices: [HorizontalPoint], center: HorizontalPoint) -> HorizontalPlatformBezierPath? {
        let contours = bridgedClosedSceneContours(from: vertices)
        if contours.count > 1 {
            return compoundPath(for: contours, center: center)
        }

        let vertices = contours.first ?? []
        guard let first = vertices.first else {
            return nil
        }

        let path = HorizontalPlatformBezierPath()
        path.move(to: pathPoint(first, center: center))
        for vertex in vertices.dropFirst() {
            path.horizonLine(to: pathPoint(vertex, center: center))
        }
        path.close()
        return path
    }

    private static func bridgedClosedSceneContours(from vertices: [HorizontalPoint]) -> [[HorizontalPoint]] {
        var outer = cleanedClosedScenePoints(vertices)
        guard outer.count >= 3 else {
            return []
        }

        var holes = [[HorizontalPoint]]()
        while let bridge = firstBridgedHole(in: outer) {
            let hole = cleanedClosedScenePoints(bridge.hole)
            let updatedOuter = cleanedClosedScenePoints(bridge.outer)
            guard hole.count >= 3, updatedOuter.count >= 3 else {
                break
            }
            holes.append(hole)
            outer = updatedOuter
        }

        return [outer] + holes
    }

    private static func firstBridgedHole(in points: [HorizontalPoint]) -> (outer: [HorizontalPoint], hole: [HorizontalPoint])? {
        guard points.count >= 7 else {
            return nil
        }

        // Horizon/Metal commonly turns a polygon-with-hole into one simple
        // contour by walking from an outer vertex to a hole vertex, around the
        // hole, and then back across the same bridge:
        //
        //  outer... A, B, hole..., B, A, outer...
        //
        // SCNShape is much happier when that topologically holeless bridge is
        // restored to real even-odd subpaths; otherwise the coincident bridge
        // edges can collapse during SceneKit's Metal tessellation.
        for outerIndex in 0..<(points.count - 3) {
            let holeStartIndex = outerIndex + 1
            for holeEndIndex in (holeStartIndex + 2)..<(points.count - 1) {
                let outerPoint = points[outerIndex]
                let holePoint = points[holeStartIndex]
                let returnHolePoint = points[holeEndIndex]
                let returnOuterPoint = points[holeEndIndex + 1]

                guard bridgeEndpointsAreClose(
                    outerPoint: outerPoint,
                    holePoint: holePoint,
                    returnHolePoint: returnHolePoint,
                    returnOuterPoint: returnOuterPoint
                ) else {
                    continue
                }

                var outer = Array(points[...outerIndex])
                outer[outer.count - 1] = midpoint(outerPoint, returnOuterPoint)
                if holeEndIndex + 2 < points.count {
                    outer.append(contentsOf: points[(holeEndIndex + 2)...])
                }
                var hole = Array(points[holeStartIndex...holeEndIndex])
                let snappedHolePoint = midpoint(holePoint, returnHolePoint)
                hole[0] = snappedHolePoint
                hole[hole.count - 1] = snappedHolePoint
                return (outer, hole)
            }
        }

        return nil
    }

    private static func bridgeEndpointsAreClose(
        outerPoint: HorizontalPoint,
        holePoint: HorizontalPoint,
        returnHolePoint: HorizontalPoint,
        returnOuterPoint: HorizontalPoint
    ) -> Bool {
        let tolerance = bridgeHealingTolerance
        guard distance(outerPoint, holePoint) > tolerance * 2,
              distance(returnHolePoint, returnOuterPoint) > tolerance * 2 else {
            return false
        }

        if pointsAreClose(outerPoint, returnOuterPoint, tolerance: tolerance)
            && pointsAreClose(holePoint, returnHolePoint, tolerance: tolerance) {
            return true
        }

        return segmentsAreCloseAndOpposed(
            outerPoint,
            holePoint,
            returnHolePoint,
            returnOuterPoint,
            tolerance: tolerance
        )
    }

    private static var bridgeHealingTolerance: Double {
        // 20 µm in Horizon board units. This is intentionally much looser than
        // the exact point-cleaning tolerance and only applies to the very
        // specific A-B...B-A bridge pattern used for holeless polygon export.
        unitsPerMillimeter * 0.02
    }

    private static func segmentsAreCloseAndOpposed(
        _ firstStart: HorizontalPoint,
        _ firstEnd: HorizontalPoint,
        _ secondStart: HorizontalPoint,
        _ secondEnd: HorizontalPoint,
        tolerance: Double
    ) -> Bool {
        let firstVector = HorizontalPoint(x: firstEnd.x - firstStart.x, y: firstEnd.y - firstStart.y)
        let secondVector = HorizontalPoint(x: secondEnd.x - secondStart.x, y: secondEnd.y - secondStart.y)
        let firstLength = hypot(firstVector.x, firstVector.y)
        let secondLength = hypot(secondVector.x, secondVector.y)
        guard firstLength > tolerance * 2, secondLength > tolerance * 2 else {
            return false
        }

        let normalizedDot = (firstVector.x * secondVector.x + firstVector.y * secondVector.y) / (firstLength * secondLength)
        guard normalizedDot < -0.96 else {
            return false
        }

        let endpointTolerance = max(tolerance * 4, min(firstLength, secondLength) * 0.08)
        guard distance(firstStart, secondEnd) <= endpointTolerance,
              distance(firstEnd, secondStart) <= endpointTolerance else {
            return false
        }

        return pointSegmentDistance(firstStart, secondStart, secondEnd) <= tolerance
            && pointSegmentDistance(firstEnd, secondStart, secondEnd) <= tolerance
            && pointSegmentDistance(secondStart, firstStart, firstEnd) <= tolerance
            && pointSegmentDistance(secondEnd, firstStart, firstEnd) <= tolerance
    }

    private static func compoundPath(for paths: [[HorizontalPoint]], center: HorizontalPoint) -> HorizontalPlatformBezierPath? {
        let path = HorizontalPlatformBezierPath()
        path.horizonUseEvenOddWinding()
        var hasPath = false

        for points in paths {
            let points = cleanedClosedScenePoints(points)
            guard let first = points.first else {
                continue
            }

            path.move(to: pathPoint(first, center: center))
            for point in points.dropFirst() {
                path.horizonLine(to: pathPoint(point, center: center))
            }
            path.close()
            hasPath = true
        }

        return hasPath ? path : nil
    }

    private static func cleanedOpenScenePoints(_ points: [HorizontalPoint]) -> [HorizontalPoint] {
        var cleaned: [HorizontalPoint] = []
        cleaned.reserveCapacity(points.count)
        for point in points where point.x.isFinite && point.y.isFinite {
            if let previous = cleaned.last, pointsAreCoincident(previous, point) {
                continue
            }
            cleaned.append(point)
        }
        return cleaned
    }

    private static func cleanedClosedScenePoints(_ points: [HorizontalPoint]) -> [HorizontalPoint] {
        var cleaned = cleanedOpenScenePoints(points)
        if cleaned.count > 1, let first = cleaned.first, let last = cleaned.last, pointsAreCoincident(first, last) {
            cleaned.removeLast()
        }

        guard cleaned.count >= 3, abs(signedArea(of: cleaned)) > 100 else {
            return []
        }
        return cleaned
    }

    private static func pointsAreCoincident(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 && abs(lhs.y - rhs.y) <= 1
    }

    private static func pointsAreClose(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint, tolerance: Double) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    private static func distance(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private static func midpoint(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> HorizontalPoint {
        HorizontalPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }

    private static func pointSegmentDistance(_ point: HorizontalPoint, _ start: HorizontalPoint, _ end: HorizontalPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return distance(point, start)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = HorizontalPoint(x: start.x + t * dx, y: start.y + t * dy)
        return distance(point, projection)
    }

    private static func signedArea(of points: [HorizontalPoint]) -> Double {
        guard points.count >= 3 else {
            return 0
        }

        var area = 0.0
        for index in points.indices {
            let nextIndex = points.index(after: index) == points.endIndex ? points.startIndex : points.index(after: index)
            area += points[index].x * points[nextIndex].y - points[nextIndex].x * points[index].y
        }
        return area / 2
    }

    private static func pathPoint(_ point: HorizontalPoint, center: HorizontalPoint) -> CGPoint {
        CGPoint(
            x: (point.x - center.x) / unitsPerMillimeter,
            y: -(point.y - center.y) / unitsPerMillimeter
        )
    }

    fileprivate static func scenePosition(_ point: HorizontalPoint, center: HorizontalPoint, y: Double) -> SCNVector3 {
        SCNVector3(
            horizonSceneScalar((point.x - center.x) / unitsPerMillimeter),
            horizonSceneScalar(y),
            horizonSceneScalar(-(point.y - center.y) / unitsPerMillimeter)
        )
    }

    fileprivate static func copperHeight(
        for layer: Int?,
        board: HorizontalBoard? = nil,
        boardThickness: Double = fallbackBoardThickness,
        layerSeparation: Double = 0
    ) -> Double {
        let baseHeight: Double
        guard let layer else {
            return boardTopHeight + 0.14 + layerSeparation
        }

        if HorizontalBoardLayers.isCopper(layer), let board {
            let locationY = copperLayerLocationY(layer, board: board, boardThickness: boardThickness)
            let thickness = copperThickness(for: layer, board: board)
            let growsPositive = layer == HorizontalBoardLayers.topCopper
            return locationY
                + (growsPositive ? thickness / 2 : -thickness / 2)
                + layerSeparationOffset(for: layer, amount: layerSeparation)
        }

        if layer == HorizontalBoardLayers.topCopper {
            baseHeight = boardTopHeight + copperVisualThickness / 2
        } else if layer == HorizontalBoardLayers.bottomCopper {
            baseHeight = boardTopHeight - boardThickness - copperVisualThickness / 2
        } else if HorizontalBoardLayers.isCopper(layer) {
            baseHeight = boardTopHeight - boardThickness / 2 - copperVisualThickness / 2
        } else {
            baseHeight = boardTopHeight + 0.14
        }
        return baseHeight + layerSeparationOffset(for: layer, amount: layerSeparation)
    }

    private static func copperLayerLocationY(
        _ layer: Int,
        board: HorizontalBoard,
        boardThickness: Double
    ) -> Double {
        if layer == HorizontalBoardLayers.topCopper {
            return boardTopHeight
        }

        if layer == HorizontalBoardLayers.bottomCopper {
            return boardTopHeight - boardThickness + copperThickness(for: layer, board: board)
        }

        let descending = board.stackupLayers.sorted { $0.layer > $1.layer }
        var y = boardTopHeight
        for entry in descending {
            if entry.layer == layer {
                return y
            }
            y -= max(entry.substrateThickness / unitsPerMillimeter, 0)
            if entry.layer != HorizontalBoardLayers.topCopper {
                y -= max(entry.copperThickness / unitsPerMillimeter, 0)
            }
        }
        return boardTopHeight - boardThickness / 2
    }

    private static func copperOuterSurfaceHeight(
        forTopSide topSide: Bool,
        board: HorizontalBoard? = nil,
        boardThickness: Double
    ) -> Double {
        if topSide {
            let centerY = copperHeight(for: HorizontalBoardLayers.topCopper, board: board, boardThickness: boardThickness)
            return centerY + copperThickness(for: HorizontalBoardLayers.topCopper, board: board) / 2
        }
        let centerY = copperHeight(for: HorizontalBoardLayers.bottomCopper, board: board, boardThickness: boardThickness)
        return centerY - copperThickness(for: HorizontalBoardLayers.bottomCopper, board: board) / 2
    }

    private static func solderMaskTopSurfaceHeight(
        for layer: Int?,
        board: HorizontalBoard? = nil,
        boardThickness: Double,
        layerSeparation: Double = 0
    ) -> Double {
        guard let layer else {
            return copperHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)
        }

        if layer == HorizontalBoardLayers.topMask {
            let baseHeight = copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: boardThickness)
                + solderMaskThickness + layerSurfaceGap
            return baseHeight + layerSeparationOffset(for: layer, amount: layerSeparation)
        }
        if layer == HorizontalBoardLayers.bottomMask {
            let baseHeight = copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: boardThickness)
                - layerSurfaceGap
            return baseHeight + layerSeparationOffset(for: layer, amount: layerSeparation)
        }

        return copperHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)
    }

    private static func solderMaskOuterSurfaceHeight(
        for layer: Int,
        board: HorizontalBoard? = nil,
        boardThickness: Double,
        layerSeparation: Double = 0
    ) -> Double {
        if layer == HorizontalBoardLayers.topMask {
            return solderMaskTopSurfaceHeight(
                for: layer,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: layerSeparation
            )
        }
        if layer == HorizontalBoardLayers.bottomMask {
            return solderMaskTopSurfaceHeight(
                for: layer,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: layerSeparation
            ) - solderMaskThickness
        }

        return copperHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)
    }

    private static func silkscreenSurfaceHeight(
        for layer: Int?,
        board: HorizontalBoard? = nil,
        boardThickness: Double,
        layerSeparation: Double = 0
    ) -> Double? {
        guard let layer else {
            return nil
        }
        if layer == HorizontalBoardLayers.topSilkscreen {
            return solderMaskOuterSurfaceHeight(
                for: HorizontalBoardLayers.topMask,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: layerSeparation
            )
        }
        if layer == HorizontalBoardLayers.bottomSilkscreen {
            return solderMaskOuterSurfaceHeight(
                for: HorizontalBoardLayers.bottomMask,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: layerSeparation
            )
        }
        return nil
    }

    private static func padTopSurfaceHeight(
        for layer: Int?,
        board: HorizontalBoard? = nil,
        boardThickness: Double,
        layerSeparation: Double = 0
    ) -> Double {
        guard let layer else {
            return copperHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)
        }

        if layer == HorizontalBoardLayers.topPaste {
            let baseHeight = copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: boardThickness)
                + solderPasteThickness / 2 + layerSurfaceGap
            return baseHeight + layerSeparationOffset(for: layer, amount: layerSeparation)
        }
        if layer == HorizontalBoardLayers.bottomPaste {
            let baseHeight = copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: boardThickness)
                - solderPasteThickness / 2 - layerSurfaceGap
            return baseHeight + layerSeparationOffset(for: layer, amount: layerSeparation)
        }
        if layer == HorizontalBoardLayers.topMask || layer == HorizontalBoardLayers.bottomMask {
            return solderMaskTopSurfaceHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)
        }

        return copperHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)
    }

    private static func padExtrusionDepth(for layer: Int?, board: HorizontalBoard? = nil) -> CGFloat {
        guard let layer else {
            return CGFloat(copperVisualThickness)
        }
        if HorizontalBoardLayers.category(for: layer) == .paste {
            return CGFloat(solderPasteThickness)
        }
        if HorizontalBoardLayers.category(for: layer) == .solderMask {
            return CGFloat(solderMaskThickness)
        }
        return CGFloat(copperThickness(for: layer, board: board))
    }

    /// Returns the SceneKit-Y coordinate of a given copper layer based on the
    /// board's stackup. Used for placing vias whose span is restricted to a
    /// subset of the copper layers (blind / buried vias).
    fileprivate static func copperLayerStackY(
        _ layer: Int,
        board: HorizontalBoard,
        boardThickness: Double
    ) -> Double {
        copperHeight(for: layer, board: board, boardThickness: boardThickness)
    }

    /// Returns the (top, bottom) SceneKit-Y span of a via given its layer
    /// connectivity. Through-holes default to the full board thickness; blind
    /// and buried vias use the via's `connectedLayers` to span only the copper
    /// layers they actually reach.
    fileprivate static func viaZSpan(
        for via: HorizontalMarker,
        board: HorizontalBoard,
        boardThickness: Double
    ) -> (top: Double, bottom: Double) {
        let copperLayers = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
        guard let topMostLayer = copperLayers.max(),
              let bottomMostLayer = copperLayers.min(),
              topMostLayer != bottomMostLayer else {
            return (
                copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: boardThickness),
                copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: boardThickness)
            )
        }
        let topY = copperUpperSurfaceHeight(for: topMostLayer, board: board, boardThickness: boardThickness)
        let bottomY = copperLowerSurfaceHeight(for: bottomMostLayer, board: board, boardThickness: boardThickness)
        return (max(topY, bottomY), min(topY, bottomY))
    }

    private static func copperUpperSurfaceHeight(
        for layer: Int,
        board: HorizontalBoard,
        boardThickness: Double
    ) -> Double {
        copperHeight(for: layer, board: board, boardThickness: boardThickness)
            + copperThickness(for: layer, board: board) / 2
    }

    private static func copperLowerSurfaceHeight(
        for layer: Int,
        board: HorizontalBoard,
        boardThickness: Double
    ) -> Double {
        copperHeight(for: layer, board: board, boardThickness: boardThickness)
            - copperThickness(for: layer, board: board) / 2
    }

    private static func planeHeight(
        for layer: Int?,
        board: HorizontalBoard? = nil,
        boardThickness: Double = fallbackBoardThickness,
        layerSeparation: Double = 0
    ) -> Double {
        copperHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation)
    }

    private static func overlayHeight(
        for layer: Int?,
        board: HorizontalBoard? = nil,
        boardThickness: Double = fallbackBoardThickness,
        layerSeparation: Double = 0
    ) -> Double {
        let baseHeight: Double
        guard let layer else {
            return boardTopHeight + 0.22 + layerSeparation
        }

        if let silkscreenHeight = silkscreenSurfaceHeight(
            for: layer,
            board: board,
            boardThickness: boardThickness,
            layerSeparation: layerSeparation
        ) {
            return silkscreenHeight
        }

        if isBottomSideLayer(layer) {
            baseHeight = boardTopHeight - boardThickness - 0.14
        } else if HorizontalBoardLayers.isCopper(layer) {
            baseHeight = copperHeight(for: layer, board: board, boardThickness: boardThickness) + layerSurfaceGap
        } else {
            baseHeight = boardTopHeight + 0.24
        }
        return baseHeight + layerSeparationOffset(for: layer, amount: layerSeparation)
    }

    private static func overlayArtworkYOffset(for layer: Int?, fallback: Double) -> Double {
        isSilkscreenLayer(layer) ? layerSurfaceGap : fallback
    }

    private static func textOverlayHeight(
        for layer: Int?,
        board: HorizontalBoard? = nil,
        boardThickness: Double,
        layerSeparation: Double = 0
    ) -> Double {
        let offset = isSilkscreenLayer(layer) ? layerSurfaceGap : 0.045
        return overlayHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation) + offset
    }

    private static func isBoardBodyLayer(_ layer: Int?) -> Bool {
        guard let layer else {
            return false
        }
        return HorizontalBoardLayers.isOutline(layer)
    }

    private static func isSilkscreenLayer(_ layer: Int?) -> Bool {
        guard let layer else { return false }
        return HorizontalBoardLayers.category(for: layer) == .silkscreen
    }

    private static func isBottomSideLayer(_ layer: Int) -> Bool {
        HorizontalBoardLayers.isBottomSide(layer)
    }

    private static func isSceneLayerVisible(_ layer: Int?, displayOptions: BoardDisplayOptions) -> Bool {
        !isExcludedFrom3DScene(layer)
            && isCopperVisible(layer, displayOptions: displayOptions)
            && displayOptions.isLayerVisible(layer)
    }

    private static func isCopperVisible(_ layer: Int?, displayOptions: BoardDisplayOptions) -> Bool {
        guard let layer, HorizontalBoardLayers.isCopper(layer) else {
            return true
        }
        return displayOptions.threeDCopperMode != .off
    }

    private static func isCourtyardLayer(_ layer: Int?) -> Bool {
        layer == HorizontalBoardLayers.topCourtyard || layer == HorizontalBoardLayers.bottomCourtyard
    }

    private static func isNotesLayer(_ layer: Int?) -> Bool {
        layer == HorizontalBoardLayers.topNotes
            || layer == HorizontalBoardLayers.bottomNotes
            || layer == HorizontalBoardLayers.outlineNotes
    }

    private static func isExcludedFrom3DScene(_ layer: Int?) -> Bool {
        isCourtyardLayer(layer) || isNotesLayer(layer)
    }

    private static func isSolderMaskLayer(_ layer: Int?) -> Bool {
        guard let layer else { return false }
        return HorizontalBoardLayers.category(for: layer) == .solderMask
    }

    private static func isPackageOrAssemblyLayer(_ layer: Int?) -> Bool {
        guard let layer else { return false }
        return layer == HorizontalBoardLayers.topPackage
            || layer == HorizontalBoardLayers.bottomPackage
            || layer == HorizontalBoardLayers.topAssembly
            || layer == HorizontalBoardLayers.bottomAssembly
    }

    private static func pointAlong(
        _ point: SCNVector3,
        direction: SCNVector3,
        distance: HorizontalSceneScalar
    ) -> SCNVector3 {
        let x = point.x + direction.x * distance
        let y = point.y + direction.y * distance
        let z = point.z + direction.z * distance
        return SCNVector3(x, y, z)
    }

    private static func vectorLength(_ vector: SCNVector3) -> HorizontalSceneScalar {
        let squaredLength = vector.x * vector.x + vector.y * vector.y + vector.z * vector.z
        return sqrt(squaredLength)
    }

    private static func dot(_ lhs: SCNVector3, _ rhs: SCNVector3) -> HorizontalSceneScalar {
        let x = lhs.x * rhs.x
        let y = lhs.y * rhs.y
        let z = lhs.z * rhs.z
        return x + y + z
    }

    private static func cross(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
        let x = lhs.y * rhs.z - lhs.z * rhs.y
        let y = lhs.z * rhs.x - lhs.x * rhs.z
        let z = lhs.x * rhs.y - lhs.y * rhs.x
        return SCNVector3(x, y, z)
    }

}

private extension HorizontalRGBColor {
    var nsColor: HorizontalPlatformColor {
        HorizontalPlatformColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

#if canImport(AppKit)
public enum HorizontalBoardPreviewRenderer {
    public static func image(forProjectAt url: URL, fitting requestedSize: CGSize) throws -> NSImage {
        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var result: Result<NSImage, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try imageWithoutCoordination(forProjectAt: coordinatedURL, fitting: requestedSize)
            }
        }

        if let result {
            return try result.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw previewError("Quick Look could not coordinate access to \(url.lastPathComponent).")
    }

    private static func imageWithoutCoordination(forProjectAt url: URL, fitting requestedSize: CGSize) throws -> NSImage {
        var projectLoadError: Error?
        do {
            let project = try HorizontalProject.load(from: url)
            if let board = project.board {
                return image(for: board, fitting: requestedSize)
            }
            projectLoadError = previewError("The project does not contain a board.")
        } catch {
            projectLoadError = error
        }

        do {
            let board = try loadBoardDirectly(from: url)
            return image(for: board, fitting: requestedSize)
        } catch {
            throw projectLoadError ?? error
        }
    }

    private static func loadBoardDirectly(from url: URL) throws -> HorizontalBoard {
        let baseURL = try boardBaseURL(for: url)
        let boardURL = baseURL.appendingPathComponent("board.json")
        guard FileManager.default.fileExists(atPath: boardURL.path) else {
            throw previewError("\(url.lastPathComponent) does not contain board.json.")
        }

        let blockURL = fallbackBlockURL(in: baseURL)
        let planesURL = existingFileURL(baseURL.appendingPathComponent("planes.json"))
        let poolURL = existingDirectoryURL(baseURL.appendingPathComponent("pool"))
        var diagnostics = [HorizontalDiagnostic]()
        return try HorizontalBoard.load(
            from: boardURL,
            blockURL: blockURL,
            planesURL: planesURL,
            poolURL: poolURL,
            diagnostics: &diagnostics
        )
    }

    private static func boardBaseURL(for url: URL) throws -> URL {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw previewError("\(url.lastPathComponent) does not exist.")
        }
        if isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private static func fallbackBlockURL(in baseURL: URL) -> URL? {
        let blocksURL = baseURL.appendingPathComponent("blocks.json")
        if let blocksJSON = try? JSONHelper.loadDictionary(from: blocksURL) {
            let blocksMap = blocksJSON.dictionaryMap("blocks")
            if let topBlockID = blocksJSON.string("top_block"),
               let topBlockFilename = blocksMap[topBlockID]?.string("block_filename") {
                return existingFileURL(baseURL.appendingPathComponent(topBlockFilename))
            }
            for block in blocksMap.values {
                if let blockFilename = block.string("block_filename"),
                   let url = existingFileURL(baseURL.appendingPathComponent(blockFilename)) {
                    return url
                }
            }
        }
        return existingFileURL(baseURL.appendingPathComponent("top_block.json"))
    }

    private static func existingFileURL(_ url: URL) -> URL? {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func existingDirectoryURL(_ url: URL) -> URL? {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func previewError(_ message: String) -> NSError {
        NSError(
            domain: "com.twarge.horizontal.QuickLook",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func image(for board: HorizontalBoard, fitting requestedSize: CGSize) -> NSImage {
        let size = CGSize(
            width: max(requestedSize.width.rounded(.up), 96),
            height: max(requestedSize.height.rounded(.up), 96)
        )
        let nodes = BoardSceneFactory.buildQuickLookScene(for: board)
        var displayOptions = BoardDisplayOptions()
        displayOptions.threeDProjection = .perspective
        displayOptions.threeDCopperMode = .on
        displayOptions.threeDModelMode = .placed
        displayOptions.threeDBackground = true
        displayOptions.connectionLines = false
        displayOptions.origin = false
        displayOptions.orientationAxes = false
        displayOptions.panelLabels = false

        let background = HorizontalDefaultTheme.background
        nodes.scene.background.contents = HorizontalDefaultTheme.backgroundNS
        nodes.applyDisplayOptions(
            displayOptions,
            backgroundColor: background,
            copperColor: Color(red: 0.72, green: 0.45, blue: 0.2),
            materialColors: HorizontalBoardColors(
                silkscreen: board.colors.silkscreen,
                solderMask: board.colors.solderMask,
                substrate: board.colors.substrate
            ),
            layerColors: [:],
            board: board
        )

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = nodes.scene
        renderer.pointOfView = nodes.cameraNode
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(
            atTime: 0,
            with: size,
            antialiasingMode: .multisampling4X
        )
    }
}
#endif
