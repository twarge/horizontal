import CoreGraphics
import Foundation
import Metal
import RealityKit
import simd
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A board's 3D scene as RealityKit entities, made on the main actor from the
/// description the background build produced, with the groups, materials and
/// explode containers that let display options change it in place.
@MainActor
final class BoardSceneEntities {
    let description: BoardSceneDescription
    /// Everything the scene draws hangs off this.
    let root = Entity()

    var board: HorizontalBoard { description.board }
    var boardThickness: Double { description.boardThickness }
    var boardWidth: Double { description.boardWidth }
    var boardDepth: Double { description.boardDepth }

    private var groups = [BoardSceneGroup: Entity]()

    /// Exploding moves whole layers, so every entity that explodes sits under
    /// a container for its (group, explode factor) and only the containers
    /// move: a few dozen transforms, however many meshes.
    private struct ContainerKey: Hashable {
        var group: BoardSceneGroup
        var factorMilli: Int
    }
    private var containers = [ContainerKey: (entity: Entity, factor: Double)]()
    /// The layer separation the containers sit at.
    private var appliedLayerSeparation = 0.0

    /// An entity whose materials follow the view's colours.
    private struct Recolorable {
        var entity: Entity
        var materials: [BoardSceneMaterialSpec]
        var role: BoardSceneMaterialRole
    }
    private var recolorables = [Recolorable]()
    private var appliedPalette: Palette?

    /// A package's model where it stands, for picking and marking.
    private struct PackagePlacement {
        var packageID: String
        var componentID: String?
        var group: BoardSceneGroup
        var container: ContainerKey
        var transform: simd_float4x4
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
        var hasBounds: Bool
    }
    private var packages = [PackagePlacement]()
    private var hiddenGroups = Set<BoardSceneGroup>()

    private var highlightMarks = [String: Entity]()
    private var selectionMarks = [String: Entity]()

    /// Via barrels and rings are tubes of a handful of sizes: one unit-high
    /// mesh per pair of radii, drawn once per barrel or ring as an instance
    /// stretched to its height.
    private struct TubeKey: Hashable {
        var innerMicrons: Int
        var outerMicrons: Int
    }
    private struct ViaLayout: Equatable {
        var layerSeparation: Double
        var platingMicrons: Double
    }
    private var viaEntities = [Entity]()
    private var appliedViaLayout: ViaLayout?
    private var viaMaterial: BoardSceneMaterialSpec?

    private(set) var statistics = Statistics()

    struct Statistics: Equatable {
        var meshes = 0
        var vertices = 0
        var triangles = 0
        var modelInstances = 0
        var modelDraws = 0
        var viaInstances = 0
        var viaDraws = 0
    }

    init(description: BoardSceneDescription) {
        self.description = description
        root.name = "board-scene"
        for group in BoardSceneGroup.allCases {
            let entity = Entity()
            entity.name = "group:\(group)"
            root.addChild(entity)
            groups[group] = entity
        }
        for item in description.meshes {
            addMesh(item)
        }
        for label in description.labels {
            addLabel(label)
        }
        addModels(description.models)
        addLights(description.lights)
    }

    // MARK: Building

    private func parent(for group: BoardSceneGroup, explodeFactor: Double?) -> (entity: Entity, container: ContainerKey?) {
        guard let explodeFactor else {
            return (groups[group]!, nil)
        }
        let key = ContainerKey(group: group, factorMilli: Int((explodeFactor * 1_000).rounded()))
        if let existing = containers[key] {
            return (existing.entity, key)
        }
        let container = Entity()
        container.name = "explode:\(key.factorMilli)"
        container.position = SIMD3(0, Float(explodeFactor * appliedLayerSeparation), 0)
        groups[group]!.addChild(container)
        containers[key] = (container, explodeFactor)
        return (container, key)
    }

    private func addMesh(_ item: BoardSceneMeshItem) {
        guard !item.mesh.isEmpty, let mesh = try? Self.meshResource(item.mesh) else {
            return
        }
        let entity = ModelEntity(mesh: mesh, materials: item.materials.map(BoardSceneMaterials.material))
        entity.name = item.name
        if let order = item.drawOrder {
            entity.components.set(ModelSortGroupComponent(group: Self.sortGroup, order: order.rawValue))
        }
        parent(for: item.group, explodeFactor: item.explodeFactor).entity.addChild(entity)
        if item.role != .fixed {
            recolorables.append(Recolorable(entity: entity, materials: item.materials, role: item.role))
        }
        statistics.meshes += 1
        statistics.vertices += item.mesh.vertexCount
        statistics.triangles += item.mesh.indices.count / 3
    }

    private func addLabel(_ label: BoardSceneLabel) {
        #if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: 1, weight: label.bold ? .bold : .semibold)
        #else
        let font = UIFont.systemFont(ofSize: 1, weight: label.bold ? .bold : .semibold)
        #endif
        let mesh = MeshResource.generateText(label.text, extrusionDepth: label.bold ? 0.01 : 0.008, font: font)
        let material = BoardSceneMaterialSpec(
            color: label.color.opaque,
            emission: label.color.withAlpha(label.bold ? 0.18 : 0.08),
            opacity: label.color.alpha
        )
        let text = ModelEntity(mesh: mesh, materials: [BoardSceneMaterials.material(material)])
        let bounds = mesh.bounds
        text.position = SIMD3(-bounds.center.x, -bounds.center.y, 0)
        let holder = Entity()
        holder.name = "label:\(label.text)"
        holder.position = label.position
        holder.scale = SIMD3(repeating: label.scale)
        holder.components.set(BillboardComponent())
        holder.addChild(text)
        groups[label.group]!.addChild(holder)
    }

    /// Every model a board places, one draw per distinct model and look: the
    /// placements of one model are instances of one mesh.
    private func addModels(_ models: [BoardSceneModelPlacement]) {
        struct InstanceKey: Hashable {
            var asset: String
            var container: ContainerKey
        }
        var order = [InstanceKey]()
        var placementsByKey = [InstanceKey: [BoardSceneModelPlacement]]()
        for placement in models {
            let (_, container) = parent(for: placement.group, explodeFactor: placement.explodeFactor)
            guard let container else {
                continue
            }
            let key = InstanceKey(asset: placement.asset.key, container: container)
            if placementsByKey[key] == nil {
                order.append(key)
            }
            placementsByKey[key, default: []].append(placement)
            let mesh = placement.asset.mesh
            packages.append(PackagePlacement(
                packageID: placement.packageID,
                componentID: placement.componentID,
                group: placement.group,
                container: container,
                transform: placement.transform,
                boundsMin: mesh.boundsMin,
                boundsMax: mesh.boundsMax,
                hasBounds: mesh.hasBounds
            ))
        }
        for key in order {
            guard let placements = placementsByKey[key], let asset = placements.first?.asset,
                  let mesh = BoardSceneMeshResources.shared.mesh(for: asset) else {
                continue
            }
            let materials = asset.materials.map(BoardSceneMaterials.material)
            let entity = ModelEntity(mesh: mesh, materials: materials)
            entity.name = "model:\(asset.key)"
            if placements.count == 1 {
                entity.transform = Transform(matrix: placements[0].transform)
            } else if let instances = try? LowLevelInstanceData(instanceCount: placements.count),
                      let component = Self.instances(of: mesh, transforms: placements.map(\.transform), data: instances) {
                entity.components.set(component)
            } else {
                continue
            }
            containers[key.container]?.entity.addChild(entity)
            statistics.modelInstances += placements.count
            statistics.modelDraws += 1
        }
    }

    private func addLights(_ lights: [BoardSceneLight]) {
        let size = Float(max(boardWidth, boardDepth))
        for (index, light) in lights.enumerated() {
            let entity = Entity()
            entity.name = "light:\(index)"
            entity.components.set(DirectionalLightComponent(color: .white, intensity: light.intensity))
            if light.castsShadow {
                entity.components.set(DirectionalLightComponent.Shadow(maximumDistance: size * 8 + 400, depthBias: 0.6))
            }
            let from = -light.direction * size
            entity.look(at: .zero, from: from, relativeTo: nil)
            root.addChild(entity)
        }
    }

    static let sortGroup = ModelSortGroup()

    /// `data` as a mesh: its interleaved vertices and indices copied straight
    /// into the GPU's buffers.
    static func meshResource(_ data: BoardSceneMeshData) throws -> MeshResource {
        let stride = MemoryLayout<Float>.size * BoardSceneMeshData.floatsPerVertex
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: data.vertexCount,
            vertexAttributes: [
                LowLevelMesh.Attribute(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                LowLevelMesh.Attribute(semantic: .normal, format: .float3, layoutIndex: 0, offset: MemoryLayout<Float>.size * 3),
            ],
            vertexLayouts: [LowLevelMesh.Layout(bufferIndex: 0, bufferOffset: 0, bufferStride: stride)],
            indexCapacity: data.indices.count,
            indexType: .uint32
        )
        let mesh = try LowLevelMesh(descriptor: descriptor)
        data.vertices.withUnsafeBytes { source in
            mesh.withUnsafeMutableBytes(bufferIndex: 0) { destination in
                destination.copyMemory(from: source)
            }
        }
        data.indices.withUnsafeBytes { source in
            mesh.withUnsafeMutableIndices { destination in
                destination.copyMemory(from: source)
            }
        }
        let bounds = data.hasBounds ? BoundingBox(min: data.boundsMin, max: data.boundsMax) : BoundingBox()
        mesh.parts.replaceAll(data.parts.map { part in
            LowLevelMesh.Part(
                indexOffset: part.indexOffset * MemoryLayout<UInt32>.size,
                indexCount: part.indexCount,
                topology: .triangle,
                materialIndex: part.materialIndex,
                bounds: bounds
            )
        })
        return try MeshResource(from: mesh)
    }

    private static func instances(of mesh: MeshResource, transforms: [simd_float4x4], data: LowLevelInstanceData) -> MeshInstancesComponent? {
        data.withMutableTransforms { destination in
            for (index, transform) in transforms.enumerated() {
                destination[index] = transform
            }
        }
        return try? MeshInstancesComponent(mesh: mesh, instances: data)
    }

    // MARK: Display options

    /// The colours the view gives the board, as the materials need them.
    private struct Palette: Equatable {
        var substrate: BoardSceneColor
        var solderMask: BoardSceneColor
        var solderMaskOpacity: Float
        var silkscreen: BoardSceneColor
        var copper: BoardSceneColor
        var usesLayerColors: Bool
        var layerColors: [Int: HorizontalRGBColor]
    }

    func applyDisplayOptions(
        _ options: BoardDisplayOptions,
        copperColor: Color,
        materialColors: HorizontalBoardColors,
        layerColors: [Int: HorizontalRGBColor]
    ) {
        let surfaces = BoardSceneSurfaceVisibility(options)
        var hidden = Set<BoardSceneGroup>()
        func hide(_ group: BoardSceneGroup, _ isHidden: Bool) {
            if isHidden { hidden.insert(group) }
        }
        hide(.substrate, !surfaces.substrate)
        hide(.solderMask, !surfaces.solderMask)
        hide(.silkscreen, !surfaces.silkscreen)
        hide(.paste, !surfaces.paste)
        hide(.copper, options.threeDCopperMode == .off)
        // Planes are copper: in 3D they follow the copper mode, the same as
        // every other copper group.
        hide(.plane, options.threeDCopperMode == .off)
        hide(.via, !options.vias || options.threeDCopperMode == .off)
        hide(.hole, !options.holes)
        hide(.model, options.threeDModelMode == .none)
        hide(.noPopulateModel, options.threeDModelMode != .all)
        hide(.placeholderModel, options.threeDModelMode != .all)
        hide(.text, !options.text)
        hide(.packageArt, !options.packages)
        hide(.decal, !options.decals)
        hide(.keepout, !options.keepouts)
        hide(.origin, !options.origin)
        hide(.orientationAxes, !options.orientationAxes)
        hide(.outline, !options.outline)
        hide(.panelLabel, !options.panelLabels)
        for (group, entity) in groups {
            let enabled = !hidden.contains(group)
            if entity.isEnabled != enabled {
                entity.isEnabled = enabled
            }
        }
        hiddenGroups = hidden

        let copper = BoardSceneColor(horizonScenePlatformColor(copperColor))
        let palette = Palette(
            substrate: materialColors.substrate.map(BoardSceneColor.init)
                ?? BoardSceneColor(HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.outline)),
            solderMask: materialColors.solderMask.map(BoardSceneColor.init)
                ?? BoardSceneColor(HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.topMask)),
            solderMaskOpacity: Float(max(0, min(1, 1 - options.threeDSolderMaskTransparency))),
            silkscreen: materialColors.silkscreen.map(BoardSceneColor.init)
                ?? BoardSceneColor(HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.topSilkscreen)),
            copper: copper,
            usesLayerColors: options.threeDCopperMode == .layerColor,
            layerColors: layerColors
        )
        if palette != appliedPalette {
            appliedPalette = palette
            for recolorable in recolorables {
                let specs = recolorable.materials.map { Self.recolored($0, role: recolorable.role, palette: palette) }
                recolorable.entity.components[ModelComponent.self]?.materials = specs.map(BoardSceneMaterials.material)
            }
        }

        let layerSeparation = max(0, min(options.threeDExplode, 12))
        if layerSeparation != appliedLayerSeparation {
            appliedLayerSeparation = layerSeparation
            for (_, container) in containers {
                var transform = container.entity.transform
                transform.translation.y = Float(container.factor * layerSeparation)
                container.entity.move(to: transform, relativeTo: container.entity.parent, duration: 0.15, timingFunction: .easeInOut)
            }
        }

        let viaLayout = ViaLayout(layerSeparation: layerSeparation, platingMicrons: options.threeDViaPlatingMicrons)
        let viaMaterial = BoardSceneMaterialSpec.copper(copper)
        if viaLayout != appliedViaLayout {
            appliedViaLayout = viaLayout
            self.viaMaterial = viaMaterial
            rebuildVias(viaLayout, material: viaMaterial)
        } else if viaMaterial != self.viaMaterial {
            self.viaMaterial = viaMaterial
            let material = BoardSceneMaterials.material(viaMaterial)
            for entity in viaEntities {
                entity.components[ModelComponent.self]?.materials = [material]
            }
        }
    }

    private static func recolored(_ spec: BoardSceneMaterialSpec, role: BoardSceneMaterialRole, palette: Palette) -> BoardSceneMaterialSpec {
        var spec = spec
        switch role {
        case .fixed:
            break
        case .substrate:
            spec.color = palette.substrate.opaque
            spec.opacity = 1
        case .solderMask:
            spec.color = palette.solderMask.opaque
            spec.emission = palette.solderMask.withAlpha(0.08)
            spec.roughness = 0.62
            spec.opacity = palette.solderMaskOpacity
            // Sidedness stays with whoever built the material: the slabs
            // are single-sided on purpose (see `solderMaskMaterial`).
        case .silkscreen:
            spec.color = palette.silkscreen.opaque
            spec.emission = palette.silkscreen.withAlpha(0.16)
        case .copper(let layer):
            if palette.usesLayerColors {
                guard let color = palette.layerColors[layer] else {
                    return spec
                }
                return .copper(BoardSceneColor(color), writesDepth: spec.writesDepth)
            }
            return .copper(palette.copper, writesDepth: spec.writesDepth)
        }
        return spec
    }

    // MARK: Vias

    private func rebuildVias(_ layout: ViaLayout, material spec: BoardSceneMaterialSpec) {
        for entity in viaEntities {
            entity.removeFromParent()
        }
        viaEntities = []
        statistics.viaInstances = 0
        statistics.viaDraws = 0

        let center = description.center
        let layerSeparation = layout.layerSeparation
        let platingThickness = max(0, min(layout.platingMicrons, 250)) / 1_000
        let padThickness = 0.04
        var order = [TubeKey]()
        var transformsByTube = [TubeKey: [simd_float4x4]]()
        func add(inner: Double, outer: Double, height: Double, at point: HorizontalPoint, y: Double) {
            guard outer > inner, height > 0 else {
                return
            }
            let key = TubeKey(innerMicrons: Int((inner * 1_000).rounded()), outerMicrons: Int((outer * 1_000).rounded()))
            guard key.outerMicrons > key.innerMicrons else {
                return
            }
            if transformsByTube[key] == nil {
                order.append(key)
            }
            var transform = simd_float4x4(translation: BoardSceneFactory.scenePoint(point, center: center, y: y))
            transform.columns.1.y = Float(height)
            transformsByTube[key, default: []].append(transform)
        }

        for via in description.vias {
            let outerRadius = max((via.size / BoardSceneFactory.unitsPerMillimeter) / 2, 0.18)
            let drillDiameter = max((via.holeSize ?? via.size * 0.5) / BoardSceneFactory.unitsPerMillimeter, 0.05)
            let holeRadius = max(drillDiameter / 2, 0.04)
            let barrelInnerRadius = max(holeRadius - platingThickness, 0.001)

            let copperLayers = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
            let topLayer = copperLayers.max() ?? HorizontalBoardLayers.topCopper
            let bottomLayer = copperLayers.min() ?? HorizontalBoardLayers.bottomCopper
            let span = BoardSceneFactory.viaZSpan(for: via, board: board, boardThickness: boardThickness)
            let topExplodeOffset = BoardSceneFactory.explodeFactor(for: topLayer, board: board, boardThickness: boardThickness) * layerSeparation
            let bottomExplodeOffset = BoardSceneFactory.explodeFactor(for: bottomLayer, board: board, boardThickness: boardThickness) * layerSeparation
            let explodedTop = span.top + topExplodeOffset + platingThickness
            let explodedBottom = span.bottom + bottomExplodeOffset - platingThickness
            add(
                inner: barrelInnerRadius, outer: holeRadius,
                height: max(explodedTop - explodedBottom, 0.18),
                at: via.position, y: (explodedTop + explodedBottom) / 2
            )

            // No ring for a barrel that only plates a hole in a pad that
            // draws its own copper.
            guard via.size > (via.holeSize ?? 0) + 2_000, outerRadius > holeRadius + 0.001 else {
                continue
            }
            let layersToMark = copperLayers.isEmpty
                ? [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
                : copperLayers
            for layer in layersToMark {
                let layerY = BoardSceneFactory.copperHeight(for: layer, board: board, boardThickness: boardThickness)
                let explodeOffset = BoardSceneFactory.explodeFactor(for: layer, board: board, boardThickness: boardThickness) * layerSeparation
                let copperThickness = BoardSceneFactory.copperThickness(for: layer, board: board, fallback: padThickness)
                let isTop = layer == HorizontalBoardLayers.topCopper
                let isBottom = layer == HorizontalBoardLayers.bottomCopper
                let extra = (isTop || isBottom) ? platingThickness : 0
                let centerOffset = isTop ? extra / 2 : (isBottom ? -extra / 2 : 0)
                add(
                    inner: holeRadius, outer: outerRadius,
                    height: copperThickness + extra,
                    at: via.position, y: layerY + explodeOffset + centerOffset
                )
            }
        }

        let material = BoardSceneMaterials.material(spec)
        let viaGroup = groups[.via]!
        for key in order {
            guard let transforms = transformsByTube[key],
                  let mesh = BoardSceneMeshResources.shared.tube(innerMicrons: key.innerMicrons, outerMicrons: key.outerMicrons),
                  let data = try? LowLevelInstanceData(instanceCount: transforms.count),
                  let component = Self.instances(of: mesh, transforms: transforms, data: data) else {
                continue
            }
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = "vias:\(key.innerMicrons)-\(key.outerMicrons)"
            entity.components.set(component)
            viaGroup.addChild(entity)
            viaEntities.append(entity)
            statistics.viaInstances += transforms.count
            statistics.viaDraws += 1
        }
    }

    // MARK: Picking

    /// The component whose model is nearest along `ray`, unless the board
    /// is nearer: what a click at that point of the view is on.
    func componentID(along ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> String? {
        var nearest = Float.greatestFiniteMagnitude
        var nearestComponent: String?
        if !hiddenGroups.contains(.substrate),
           let distance = Self.intersection(origin: ray.origin, direction: ray.direction, boxMin: description.boardBoxMin, boxMax: description.boardBoxMax) {
            nearest = distance
        }
        for package in packages where !hiddenGroups.contains(package.group) {
            // The ray in the model's own space, where its bounds are a box;
            // its direction unnormalised, so distances along it compare.
            let inverse = (containerTransform(package.container) * package.transform).inverse
            let origin = inverse.transformPoint(ray.origin)
            let direction4 = inverse * SIMD4(ray.direction, 0)
            let direction = SIMD3(direction4.x, direction4.y, direction4.z)
            let local = Self.localBounds(of: package)
            if let distance = Self.intersection(origin: origin, direction: direction, boxMin: local.min, boxMax: local.max),
               distance < nearest {
                nearest = distance
                nearestComponent = package.componentID
            }
        }
        return nearestComponent
    }

    private func containerTransform(_ key: ContainerKey) -> simd_float4x4 {
        let factor = containers[key]?.factor ?? 0
        return simd_float4x4(translation: SIMD3(0, Float(factor * appliedLayerSeparation), 0))
    }

    private static func localBounds(of package: PackagePlacement) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        if package.hasBounds {
            return (package.boundsMin, package.boundsMax)
        }
        return (SIMD3(-0.5, 0, -0.5), SIMD3(0.5, 0.6, 0.5))
    }

    /// Where a ray first meets a box, as a multiple of its direction; nil
    /// when it misses or the box is behind it.
    nonisolated static func intersection(origin: SIMD3<Float>, direction: SIMD3<Float>, boxMin: SIMD3<Float>, boxMax: SIMD3<Float>) -> Float? {
        var near = -Float.greatestFiniteMagnitude
        var far = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            if abs(direction[axis]) < 1e-9 {
                if origin[axis] < boxMin[axis] || origin[axis] > boxMax[axis] {
                    return nil
                }
                continue
            }
            var t1 = (boxMin[axis] - origin[axis]) / direction[axis]
            var t2 = (boxMax[axis] - origin[axis]) / direction[axis]
            if t1 > t2 { swap(&t1, &t2) }
            near = max(near, t1)
            far = min(far, t2)
            if near > far {
                return nil
            }
        }
        if far < 0 {
            return nil
        }
        return max(near, 0)
    }

    // MARK: Highlight and selection

    /// Marks the packages of `componentIDs` with a translucent box around each
    /// model, and a light that lights what is around it, and unmarks the
    /// rest. The marks sit in the models' containers, so they explode, hide
    /// and show with them; the models themselves are not touched, because
    /// their materials are shared by every instance.
    func applyHighlight(componentIDs: Set<String>) {
        mark(componentIDs: componentIDs, marks: &highlightMarks) { package in
            self.markBox(around: package, color: Self.highlightColor, alpha: 0.45, pad: 0.5, lit: true)
        }
        // More lights than this flood the board, and cost more than the
        // boxes need: past it, the boxes mark the parts alone.
        let lit = highlightMarks.count <= Self.highlightLightBudget
        for box in highlightMarks.values {
            box.findEntity(named: Self.highlightLightName)?.isEnabled = lit
        }
    }

    /// Marks the packages of `componentIDs` as selected: a blue box, thinner
    /// than the highlight's and without its light, so both can show at once.
    func applySelection(componentIDs: Set<String>) {
        mark(componentIDs: componentIDs, marks: &selectionMarks) { package in
            self.markBox(around: package, color: Self.selectionColor, alpha: 0.34, pad: 0.3, lit: false)
        }
    }

    /// Every mark in the scene: the highlight's and the selection's.
    var markCount: Int {
        highlightMarks.count + selectionMarks.count
    }

    /// The highlight lights that light the scene.
    var highlightLights: [Entity] {
        highlightMarks.values.compactMap { $0.findEntity(named: Self.highlightLightName) }.filter(\.isEnabled)
    }

    private func mark(componentIDs: Set<String>, marks: inout [String: Entity], make: (PackagePlacement) -> Entity) {
        let wanted = Set(componentIDs.map { $0.lowercased() })
        var keep = Set<String>()
        for package in packages {
            guard let componentID = package.componentID, wanted.contains(componentID.lowercased()) else {
                continue
            }
            keep.insert(package.packageID)
            if marks[package.packageID] == nil {
                let box = make(package)
                containers[package.container]?.entity.addChild(box)
                marks[package.packageID] = box
            }
        }
        for (packageID, box) in marks where !keep.contains(packageID) {
            box.removeFromParent()
            marks[packageID] = nil
        }
    }

    private static let highlightColor = BoardSceneColor(red: 1.0, green: 0.16, blue: 0.10)
    private static let selectionColor = BoardSceneColor(red: 0.25, green: 0.56, blue: 1.0)

    static let highlightLightName = "highlight-light"
    /// How many highlighted parts light their surroundings. A GPU before
    /// Apple's family 6 draws eight dynamic lights at most, and the scene's
    /// own four take half of them.
    static let highlightLightBudget = MTLCreateSystemDefaultDevice()?.supportsFamily(.apple6) == true ? 8 : 4

    /// The axis-aligned box the package's model fills where it stands, in
    /// its container's space.
    private func markBounds(of package: PackagePlacement) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard package.hasBounds else {
            let center = package.transform.transformPoint(.zero)
            return (center + SIMD3(-0.5, 0, -0.5), center + SIMD3(0.5, 0.6, 0.5))
        }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in 0..<8 {
            let local = SIMD3(
                corner & 1 == 0 ? package.boundsMin.x : package.boundsMax.x,
                corner & 2 == 0 ? package.boundsMin.y : package.boundsMax.y,
                corner & 4 == 0 ? package.boundsMin.z : package.boundsMax.z
            )
            let point = package.transform.transformPoint(local)
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        return (low, high)
    }

    /// A self-lit box around the part in `color`, and — with `lit` — a light
    /// of that colour over it, which lights the board and the parts beside
    /// it. The box is unlit, so it reads as its colour whatever the light.
    private func markBox(around package: PackagePlacement, color: BoardSceneColor, alpha: Double, pad: Float, lit: Bool) -> Entity {
        var (low, high) = markBounds(of: package)
        if [low.x, low.y, low.z, high.x, high.y, high.z].contains(where: { !$0.isFinite }) || high.x < low.x || high.y < low.y || high.z < low.z {
            low = SIMD3(-0.5, 0, -0.5)
            high = SIMD3(0.5, 0.6, 0.5)
        }
        let width = max(high.x - low.x, 0.6) + pad
        let height = max(high.y - low.y, 0.4) + pad
        let length = max(high.z - low.z, 0.6) + pad
        let box = ModelEntity(
            mesh: .generateBox(width: width, height: height, depth: length, cornerRadius: 0.12),
            materials: [BoardSceneMaterials.material(Self.glow(color, alpha: alpha))]
        )
        box.name = lit ? "highlight" : "selection"
        box.position = (low + high) / 2
        box.components.set(ModelSortGroupComponent(group: Self.sortGroup, order: BoardSceneDrawOrder.mark.rawValue))
        if lit {
            box.addChild(Self.highlightLight(color: color, footprint: max(width, length), height: height, bottom: package.container.factorMilli < 0))
        }
        return box
    }

    /// A point light over the middle of a highlighted part — under it, for a
    /// part on the bottom — so the part seems to light the board and the
    /// parts around it, where SceneKit's view drew a translucent sphere. It
    /// hangs higher over a bigger part, to spread wider, is bright enough to
    /// light the board at the part's edge alike whatever the part's size, and
    /// lights nothing on the board past a few millimetres beyond the part,
    /// further for a bigger one.
    private static func highlightLight(color: BoardSceneColor, footprint: Float, height: Float, bottom: Bool) -> Entity {
        let lift = 1.5 + 0.35 * footprint
        let overBoard = height + lift
        let glowRadius = 5 + 1.2 * footprint
        let toEdge = (footprint * footprint / 4 + overBoard * overBoard).squareRoot()
        // Lux on the board at the part's edge; the key light gives 2,600.
        let illuminance: Float = 14_000
        let light = Entity()
        light.name = highlightLightName
        light.components.set(PointLightComponent(
            color: color.opaque.platformColor,
            intensity: illuminance * 4 * .pi * toEdge * toEdge * toEdge / overBoard,
            attenuationRadius: (overBoard * overBoard + glowRadius * glowRadius).squareRoot()
        ))
        light.position = SIMD3(0, (bottom ? -1 : 1) * (height / 2 + lift), 0)
        return light
    }

    private static func glow(_ color: BoardSceneColor, alpha: Double) -> BoardSceneMaterialSpec {
        BoardSceneMaterialSpec(lighting: .unlit, color: color.opaque, opacity: Float(alpha), doubleSided: true, writesDepth: false)
    }
}

/// RealityKit materials for the scene's descriptions, made once each.
@MainActor
enum BoardSceneMaterials {
    private static var cache = [BoardSceneMaterialSpec: any RealityKit.Material]()

    static func material(_ spec: BoardSceneMaterialSpec) -> any RealityKit.Material {
        if let cached = cache[spec] {
            return cached
        }
        let material: any RealityKit.Material
        switch spec.lighting {
        case .lit:
            var lit = PhysicallyBasedMaterial()
            lit.baseColor = .init(tint: spec.color.opaque.platformColor)
            lit.metallic = .init(floatLiteral: spec.metallic)
            lit.roughness = .init(floatLiteral: spec.roughness)
            if let emission = spec.emission, emission.alpha > 0 {
                lit.emissiveColor = .init(color: emission.opaque.platformColor)
                lit.emissiveIntensity = emission.alpha
            }
            if spec.opacity < 1 {
                lit.blending = .transparent(opacity: .init(floatLiteral: spec.opacity))
            }
            lit.faceCulling = spec.doubleSided ? .none : .back
            lit.writesDepth = spec.writesDepth
            if spec.wireframe {
                lit.triangleFillMode = .lines
            }
            material = lit
        case .unlit:
            var unlit = UnlitMaterial(color: spec.color.opaque.platformColor)
            if spec.opacity < 1 {
                unlit.blending = .transparent(opacity: .init(floatLiteral: spec.opacity))
            }
            unlit.writesDepth = spec.writesDepth
            material = unlit
        }
        cache[spec] = material
        return material
    }
}

/// Meshes the scene shares from one build to the next: package models, by
/// asset, and via tubes, by size.
@MainActor
final class BoardSceneMeshResources {
    static let shared = BoardSceneMeshResources()

    private var models = [String: MeshResource]()
    private var tubes = [Int: MeshResource]()

    func mesh(for asset: BoardSceneModelAsset) -> MeshResource? {
        if let cached = models[asset.key] {
            return cached
        }
        guard !asset.mesh.isEmpty, let mesh = try? BoardSceneEntities.meshResource(asset.mesh) else {
            return nil
        }
        models[asset.key] = mesh
        return mesh
    }

    /// A tube one millimetre high centred on its origin, its radii in
    /// microns: walls inside and out, and the annulus at each end.
    func tube(innerMicrons: Int, outerMicrons: Int) -> MeshResource? {
        let key = innerMicrons &* 1_000_003 &+ outerMicrons
        if let cached = tubes[key] {
            return cached
        }
        let inner = Float(innerMicrons) / 1_000
        let outer = Float(outerMicrons) / 1_000
        let segments = 24
        var builder = BoardSceneMeshBuilder(slotCount: 1)
        for index in 0..<segments {
            let a0 = Float(index) / Float(segments) * 2 * .pi
            let a1 = Float(index + 1) / Float(segments) * 2 * .pi
            let d0 = SIMD3(cos(a0), 0, -sin(a0))
            let d1 = SIMD3(cos(a1), 0, -sin(a1))
            // The outer wall faces out, the inner wall in toward the hole.
            let o0 = builder.addVertex(d0 * outer + SIMD3(0, -0.5, 0), normal: d0)
            let o1 = builder.addVertex(d1 * outer + SIMD3(0, -0.5, 0), normal: d1)
            let o2 = builder.addVertex(d1 * outer + SIMD3(0, 0.5, 0), normal: d1)
            let o3 = builder.addVertex(d0 * outer + SIMD3(0, 0.5, 0), normal: d0)
            builder.addTriangle(o0, o1, o2)
            builder.addTriangle(o0, o2, o3)
            let i0 = builder.addVertex(d0 * inner + SIMD3(0, -0.5, 0), normal: -d0)
            let i1 = builder.addVertex(d1 * inner + SIMD3(0, -0.5, 0), normal: -d1)
            let i2 = builder.addVertex(d1 * inner + SIMD3(0, 0.5, 0), normal: -d1)
            let i3 = builder.addVertex(d0 * inner + SIMD3(0, 0.5, 0), normal: -d0)
            builder.addTriangle(i1, i0, i3)
            builder.addTriangle(i1, i3, i2)
            for (y, normal) in [(Float(0.5), SIMD3<Float>(0, 1, 0)), (Float(-0.5), SIMD3<Float>(0, -1, 0))] {
                let c0 = builder.addVertex(d0 * inner + SIMD3(0, y, 0), normal: normal)
                let c1 = builder.addVertex(d0 * outer + SIMD3(0, y, 0), normal: normal)
                let c2 = builder.addVertex(d1 * outer + SIMD3(0, y, 0), normal: normal)
                let c3 = builder.addVertex(d1 * inner + SIMD3(0, y, 0), normal: normal)
                if y > 0 {
                    builder.addTriangle(c0, c1, c2)
                    builder.addTriangle(c0, c2, c3)
                } else {
                    builder.addTriangle(c0, c2, c1)
                    builder.addTriangle(c0, c3, c2)
                }
            }
        }
        guard let mesh = try? BoardSceneEntities.meshResource(builder.build()) else {
            return nil
        }
        tubes[key] = mesh
        return mesh
    }
}

/// The light the scene's metal reflects: a soft studio, bright overhead and
/// darker below, with a broad softbox high on one side for the copper to
/// catch. Generated, so the view and an offscreen render light alike.
@MainActor
enum BoardSceneEnvironment {
    private static var cached: EnvironmentResource?

    static var intensityExponent: Float = 0

    static func resource() -> EnvironmentResource? {
        if let cached {
            return cached
        }
        guard let image = studioImage(width: 512, height: 256),
              let resource = try? EnvironmentResource(equirectangular: image, withName: "board-studio") else {
            return nil
        }
        cached = resource
        return resource
    }

    private static func studioImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        // Rows run from the zenith (top) to the nadir (bottom).
        let sky = [
            CGColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: 1),
            CGColor(srgbRed: 0.70, green: 0.71, blue: 0.73, alpha: 1),
            CGColor(srgbRed: 0.72, green: 0.72, blue: 0.73, alpha: 1),
            CGColor(srgbRed: 0.64, green: 0.64, blue: 0.65, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: sky, locations: [0, 0.42, 0.55, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        }
        // A softbox high over the front right, where the key light is.
        let softbox = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        if let glow = CGGradient(colorsSpace: space, colors: softbox, locations: [0, 1]) {
            let center = CGPoint(x: CGFloat(width) * 0.62, y: CGFloat(height) * 0.78)
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(height) * 0.22, options: [])
        }
        return context.makeImage()
    }
}

func horizonScenePlatformColor(_ color: Color) -> HorizontalPlatformColor {
    #if canImport(AppKit)
    return NSColor(color).usingColorSpace(.sRGB) ?? HorizontalDefaultTheme.backgroundNS
    #else
    return UIColor(color)
    #endif
}

#if canImport(AppKit)
func horizonScenePlatformColor(_ color: Color, resolvingAgainst appearance: NSAppearance) -> HorizontalPlatformColor {
    var resolvedColor = HorizontalDefaultTheme.backgroundNS
    appearance.performAsCurrentDrawingAppearance {
        let nsColor = NSColor(color)
        resolvedColor = nsColor.usingColorSpace(NSColorSpace.sRGB) ?? nsColor
    }
    return resolvedColor
}
#endif

func horizonSceneEffectiveBackgroundColor(
    _ backgroundColor: Color,
    displayOptions: BoardDisplayOptions
) -> Color {
    displayOptions.threeDBackground ? backgroundColor : .horizonPlatformWindowBackground
}
