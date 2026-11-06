import Foundation
import ModelIO
import simd
#if canImport(AppKit)
import HorizontalStepImporter
#endif

/// Package models as meshes, loaded once per file and shared by every
/// placement — on screen as instances of one mesh. STEP files go through
/// OpenCascade (on the Mac, with a disk cache of the tessellation); USD, OBJ,
/// STL, PLY and Alembic through Model I/O. Scene builds run off the main
/// actor, one at a time through here.
final class BoardSceneModelLibrary: @unchecked Sendable {
    static let shared = BoardSceneModelLibrary()

    private let modelIOExtensions: Set<String> = ["abc", "obj", "ply", "stl", "usd", "usda", "usdc", "usdz"]
    private let stepExtensions: Set<String> = ["step", "stp"]
    private var assetsByURL = [URL: BoardSceneModelAsset]()
    private var failedURLs = Set<URL>()
    private var stepBoundsByURL = [URL: StepBounds]()
    private var failedStepBoundsURLs = Set<URL>()
    private var boxAssets = [String: BoardSceneModelAsset]()
    private lazy var cartesianPointExpression: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"CARTESIAN_POINT\s*\(\s*'[^']*'\s*,\s*\(\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*,\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*,\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*\)\s*\)"#,
            options: [.caseInsensitive]
        )
    }()
    private let lock = NSLock()

    private init() {}

    /// The model's mesh, or a translucent box its size when the file can't
    /// be tessellated here (STEP on the iPad).
    func asset(for model: HorizontalPackage3DModel, fallbackColor: BoardSceneColor) -> BoardSceneModelAsset? {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = model.fileURL.standardizedFileURL
        let fileExtension = fileURL.pathExtension.lowercased()

        if let cached = assetsByURL[fileURL] {
            return cached
        }
        if modelIOExtensions.contains(fileExtension) {
            guard !failedURLs.contains(fileURL) else {
                return nil
            }
            guard let asset = modelIOAsset(for: fileURL, fallbackColor: fallbackColor) else {
                failedURLs.insert(fileURL)
                return nil
            }
            assetsByURL[fileURL] = asset
            return asset
        }

        if stepExtensions.contains(fileExtension) {
            #if canImport(AppKit)
            if !failedURLs.contains(fileURL), let asset = stepAsset(for: fileURL) {
                assetsByURL[fileURL] = asset
                return asset
            }
            failedURLs.insert(fileURL)
            #endif
            return stepBoundingAsset(for: fileURL, fallbackColor: fallbackColor)
        }

        return nil
    }

    /// A box of `size` centred on its origin, shared by every placeholder of
    /// that size and look.
    func boxAsset(size: SIMD3<Float>, materials: [BoardSceneMaterialSpec]) -> BoardSceneModelAsset {
        lock.lock()
        defer { lock.unlock() }
        let key = "box:\(Int(size.x * 1_000)):\(Int(size.y * 1_000)):\(Int(size.z * 1_000)):\(materials.hashValue)"
        if let cached = boxAssets[key] {
            return cached
        }
        var builder = BoardSceneMeshBuilder(slotCount: materials.count)
        Self.appendBox(center: .zero, size: size, to: &builder, slots: Array(materials.indices))
        let asset = BoardSceneModelAsset(key: key, mesh: builder.build(), materials: materials)
        boxAssets[key] = asset
        return asset
    }

    // MARK: STEP

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

    /// The STEP mesh in scene axes (Horizon's z up becomes y up), one part
    /// per colour its faces were painted.
    private func stepAsset(for fileURL: URL) -> BoardSceneModelAsset? {
        guard let mesh = stepMesh(for: fileURL) else {
            return nil
        }
        let inputVertices = mesh.vertices
        var indicesByColor = [StepColorKey: [UInt32]]()
        let indices = mesh.indices
        for triangleStart in stride(from: 0, to: indices.count - 2, by: 3) {
            let first = Int(indices[triangleStart])
            guard first >= 0, first < inputVertices.count,
                  Int(indices[triangleStart + 1]) < inputVertices.count,
                  Int(indices[triangleStart + 2]) < inputVertices.count else {
                continue
            }
            let vertex = inputVertices[first]
            let key = StepColorKey(red: clampedColorComponent(vertex.r), green: clampedColorComponent(vertex.g), blue: clampedColorComponent(vertex.b))
            indicesByColor[key, default: []].append(contentsOf: indices[triangleStart..<(triangleStart + 3)])
        }
        guard !indicesByColor.isEmpty else {
            return nil
        }

        var data = BoardSceneMeshData()
        data.vertices.reserveCapacity(inputVertices.count * BoardSceneMeshData.floatsPerVertex)
        for vertex in inputVertices {
            let position = SIMD3(vertex.x, vertex.z, -vertex.y)
            data.vertices.append(contentsOf: [position.x, position.y, position.z, vertex.nx, vertex.nz, -vertex.ny])
            data.boundsMin = simd_min(data.boundsMin, position)
            data.boundsMax = simd_max(data.boundsMax, position)
        }
        let sortedKeys = indicesByColor.keys.sorted()
        var materials = [BoardSceneMaterialSpec]()
        for (slot, key) in sortedKeys.enumerated() {
            let colorIndices = indicesByColor[key] ?? []
            data.parts.append(BoardSceneMeshData.Part(indexOffset: data.indices.count, indexCount: colorIndices.count, materialIndex: slot))
            data.indices.append(contentsOf: colorIndices)
            materials.append(BoardSceneMaterialSpec(color: key.color, metallic: 0.02, roughness: 0.78))
        }
        return BoardSceneModelAsset(key: fileURL.path, mesh: data, materials: materials)
    }

    private func clampedColorComponent(_ value: Float) -> Int {
        max(0, min(255, Int((value * 255).rounded())))
    }
    #endif

    /// A translucent box over a solid wire box, the size of the points the
    /// file names: what a STEP model looks like where it can't be meshed.
    private func stepBoundingAsset(for fileURL: URL, fallbackColor: BoardSceneColor) -> BoardSceneModelAsset? {
        guard let bounds = stepBounds(for: fileURL) else {
            return nil
        }
        let key = "bounds:\(fileURL.path):\(fallbackColor.hashValue)"
        if let cached = boxAssets[key] {
            return cached
        }
        let size = SIMD3(Float(max(bounds.width, 0.05)), Float(max(bounds.height, 0.05)), Float(max(bounds.depth, 0.05)))
        let center = SIMD3(Float(bounds.centerX), Float(bounds.centerZ), Float(-bounds.centerY))
        let materials = [
            BoardSceneMaterialSpec(color: fallbackColor.opaque, roughness: 0.82, emission: fallbackColor.withAlpha(0.06), opacity: 0.58),
            BoardSceneMaterialSpec(
                color: BoardSceneColor(red: 1, green: 1, blue: 1),
                emission: fallbackColor.withAlpha(0.12),
                opacity: 0.22,
                wireframe: true
            ),
        ]
        var builder = BoardSceneMeshBuilder(slotCount: 2)
        Self.appendBox(center: center, size: size, to: &builder, slots: [0, 1])
        let asset = BoardSceneModelAsset(key: key, mesh: builder.build(), materials: materials)
        boxAssets[key] = asset
        return asset
    }

    private func stepBounds(for fileURL: URL) -> StepBounds? {
        if let bounds = stepBoundsByURL[fileURL] {
            return bounds
        }
        guard !failedStepBoundsURLs.contains(fileURL),
              let expression = cartesianPointExpression,
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            failedStepBoundsURLs.insert(fileURL)
            return nil
        }

        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        var bounds = StepBounds()
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
            failedStepBoundsURLs.insert(fileURL)
            return nil
        }

        stepBoundsByURL[fileURL] = bounds
        return bounds
    }

    // MARK: Model I/O

    /// Every mesh in the file, in the file's own placement of it, turned from
    /// z up to y up as the scene is, one part per material colour; a part
    /// without one takes the side's colour, a little translucent.
    private func modelIOAsset(for fileURL: URL, fallbackColor: BoardSceneColor) -> BoardSceneModelAsset? {
        let asset = MDLAsset(url: fileURL)
        guard asset.count > 0 else {
            return nil
        }
        let zUpToYUp = simd_float4x4(rotationAbout: SIMD3(1, 0, 0), angle: -.pi / 2)
        var vertices = [Float]()
        var indicesBySlot = [[UInt32]]()
        var materials = [BoardSceneMaterialSpec]()
        var slotByMaterial = [BoardSceneMaterialSpec: Int]()
        var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        func slot(for material: BoardSceneMaterialSpec) -> Int {
            if let slot = slotByMaterial[material] {
                return slot
            }
            materials.append(material)
            indicesBySlot.append([])
            slotByMaterial[material] = materials.count - 1
            return materials.count - 1
        }

        var meshes = [MDLMesh]()
        func collect(_ object: MDLObject) {
            if let mesh = object as? MDLMesh {
                meshes.append(mesh)
            }
            for child in object.children.objects {
                collect(child)
            }
        }
        for index in 0..<asset.count {
            collect(asset.object(at: index))
        }

        for mesh in meshes {
            if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
            guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
                  let normals = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) else {
                continue
            }
            let transform = zUpToYUp * MDLTransform.globalTransform(with: mesh, atTime: 0)
            let normalTransform = simd_float3x3(
                SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            ).inverse.transpose
            let base = UInt32(vertices.count / BoardSceneMeshData.floatsPerVertex)
            for index in 0..<mesh.vertexCount {
                let position = positions.dataStart.advanced(by: index * positions.stride).assumingMemoryBound(to: Float.self)
                let normal = normals.dataStart.advanced(by: index * normals.stride).assumingMemoryBound(to: Float.self)
                let point = transform.transformPoint(SIMD3(position[0], position[1], position[2]))
                var direction = normalTransform * SIMD3(normal[0], normal[1], normal[2])
                if simd_length(direction) > 0 {
                    direction = simd_normalize(direction)
                }
                vertices.append(contentsOf: [point.x, point.y, point.z, direction.x, direction.y, direction.z])
                boundsMin = simd_min(boundsMin, point)
                boundsMax = simd_max(boundsMax, point)
            }
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
                let indexBuffer = submesh.indexBuffer(asIndexType: .uInt32)
                let count = submesh.indexCount
                let pointer = indexBuffer.map().bytes.assumingMemoryBound(to: UInt32.self)
                let material = Self.material(of: submesh.material, fallbackColor: fallbackColor)
                let slot = slot(for: material)
                for index in 0..<count {
                    indicesBySlot[slot].append(base + pointer[index])
                }
            }
        }

        var data = BoardSceneMeshData()
        data.vertices = vertices
        for (slot, indices) in indicesBySlot.enumerated() where !indices.isEmpty {
            data.parts.append(BoardSceneMeshData.Part(indexOffset: data.indices.count, indexCount: indices.count, materialIndex: slot))
            data.indices.append(contentsOf: indices)
        }
        data.boundsMin = boundsMin
        data.boundsMax = boundsMax
        guard !data.isEmpty else {
            return nil
        }
        return BoardSceneModelAsset(key: fileURL.path, mesh: data, materials: materials)
    }

    private static func material(of material: MDLMaterial?, fallbackColor: BoardSceneColor) -> BoardSceneMaterialSpec {
        guard let property = material?.property(with: .baseColor) else {
            return BoardSceneMaterialSpec(color: fallbackColor.opaque, roughness: 0.82, opacity: 0.72)
        }
        var color: BoardSceneColor?
        switch property.type {
        case .color:
            if let cgColor = property.color, let components = cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, components.count >= 3 {
                color = BoardSceneColor(red: Float(components[0]), green: Float(components[1]), blue: Float(components[2]))
            }
        case .float3:
            color = BoardSceneColor(red: property.float3Value.x, green: property.float3Value.y, blue: property.float3Value.z)
        case .float4:
            color = BoardSceneColor(red: property.float4Value.x, green: property.float4Value.y, blue: property.float4Value.z)
        default:
            break
        }
        let roughness = material?.property(with: .roughness).map { $0.type == .float ? $0.floatValue : 0.6 } ?? 0.6
        let metallic = material?.property(with: .metallic).map { $0.type == .float ? $0.floatValue : 0 } ?? 0
        return BoardSceneMaterialSpec(color: color ?? fallbackColor.opaque, metallic: metallic, roughness: roughness)
    }

    // MARK: Boxes

    /// A box's six faces, each in a material slot of `slots` (one entry per
    /// slot to draw it in: a solid, then its wire).
    static func appendBox(center: SIMD3<Float>, size: SIMD3<Float>, to builder: inout BoardSceneMeshBuilder, slots: [Int]) {
        let half = size / 2
        let faces: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
        ]
        for face in faces {
            let middle = center + face.normal * half
            let u = face.u * half
            let v = face.v * half
            let corners = (middle - u - v, middle + u - v, middle + u + v, middle - u + v)
            for slot in slots {
                builder.addQuad(corners, normal: face.normal, slot: slot)
            }
        }
    }
}

private struct StepColorKey: Hashable, Comparable {
    var red: Int
    var green: Int
    var blue: Int

    static func < (lhs: StepColorKey, rhs: StepColorKey) -> Bool {
        (lhs.red, lhs.green, lhs.blue) < (rhs.red, rhs.green, rhs.blue)
    }

    var color: BoardSceneColor {
        BoardSceneColor(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255)
    }
}

/// The extent of the points a STEP file names, in its own millimetres.
private struct StepBounds {
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var minZ = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    var maxZ = -Double.greatestFiniteMagnitude
    var pointCount = 0

    var isValid: Bool { pointCount > 0 }
    var width: Double { maxX - minX }
    var depth: Double { maxY - minY }
    var height: Double { maxZ - minZ }
    var centerX: Double { (minX + maxX) / 2 }
    var centerY: Double { (minY + maxY) / 2 }
    var centerZ: Double { (minZ + maxZ) / 2 }

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
