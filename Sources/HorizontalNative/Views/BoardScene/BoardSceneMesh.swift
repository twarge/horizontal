import Foundation
import simd
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// The 3D scene in plain values: what the background build makes, and what the
// main actor turns into RealityKit entities. RealityKit's entities, meshes and
// materials all belong to the main actor, so everything slow — clipping,
// triangulating, laying out vertices — happens here, off it, and the main
// actor only copies finished buffers into the GPU's.

/// A colour as the scene keeps it: sRGB components from 0 to 1.
struct BoardSceneColor: Hashable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: HorizontalPlatformColor) {
        #if canImport(AppKit)
        let resolved = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? NSColor.black
        self.init(
            red: Float(resolved.redComponent),
            green: Float(resolved.greenComponent),
            blue: Float(resolved.blueComponent),
            alpha: Float(resolved.alphaComponent)
        )
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Float(red), green: Float(green), blue: Float(blue), alpha: Float(alpha))
        #endif
    }

    init(_ color: HorizontalRGBColor) {
        self.init(red: Float(color.red), green: Float(color.green), blue: Float(color.blue))
    }

    func withAlpha(_ alpha: Double) -> BoardSceneColor {
        BoardSceneColor(red: red, green: green, blue: blue, alpha: Float(alpha))
    }

    var opaque: BoardSceneColor {
        withAlpha(1)
    }

    var platformColor: HorizontalPlatformColor {
        #if canImport(AppKit)
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        #else
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        #endif
    }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

/// How one part of a mesh is shaded. Materials are made from these on the
/// main actor, one per distinct description, and shared.
struct BoardSceneMaterialSpec: Hashable, Sendable {
    enum Lighting: Hashable, Sendable {
        /// Physically based, lit by the scene's lights.
        case lit
        /// Its own colour whatever the light: the highlight and selection.
        case unlit
    }

    var lighting: Lighting = .lit
    /// The colour, without its opacity.
    var color: BoardSceneColor
    var metallic: Float = 0
    var roughness: Float = 0.5
    /// Light of its own: the colour, with its alpha as the strength.
    var emission: BoardSceneColor?
    var opacity: Float = 1
    var doubleSided = false
    var writesDepth = true
    /// Edges only: the wire box around a STEP model without a mesh.
    var wireframe = false

    /// SceneKit's copper: polished metal, both sides drawn.
    static func copper(_ color: BoardSceneColor, writesDepth: Bool = true) -> BoardSceneMaterialSpec {
        BoardSceneMaterialSpec(color: color.opaque, metallic: 0.95, roughness: 0.22, doubleSided: true, writesDepth: writesDepth)
    }

    static func paste(_ color: BoardSceneColor) -> BoardSceneMaterialSpec {
        BoardSceneMaterialSpec(color: color.opaque, metallic: 0.88, roughness: 0.16, doubleSided: true)
    }

    /// A translucent, faintly self-lit overlay: silkscreen, artwork, decals.
    static func overlay(_ color: BoardSceneColor, opacity: Double, emission: Double, roughness: Float) -> BoardSceneMaterialSpec {
        BoardSceneMaterialSpec(
            color: color.opaque,
            roughness: roughness,
            emission: color.withAlpha(emission),
            opacity: Float(opacity * Double(color.alpha)),
            doubleSided: true
        )
    }
}

/// What a mesh's materials follow when the 3D view's colours change.
enum BoardSceneMaterialRole: Hashable, Sendable {
    /// Keeps the colours it was built with.
    case fixed
    case substrate
    case solderMask
    case silkscreen
    /// Copper of one layer: the copper colour, or the layer's own.
    case copper(layer: Int)
}

/// The scene's groups, each shown or hidden as a whole by a display option.
enum BoardSceneGroup: Int, CaseIterable, Hashable, Sendable {
    case substrate
    case solderMask
    case silkscreen
    case paste
    case copper
    case plane
    case via
    case hole
    case model
    case noPopulateModel
    case placeholderModel
    case text
    case packageArt
    case decal
    case keepout
    case origin
    case orientationAxes
    case outline
    case panelLabel
    /// The shadows of the placed models, shown while they are the models
    /// shown.
    case shadow
    /// The shadows of every model, placeholders and parts not fitted too,
    /// shown while all of them are.
    case allModelShadow
}

/// Translucent surfaces lie microns apart, too close for sorting by distance
/// to keep them in order; these draw them from the board outwards.
enum BoardSceneDrawOrder: Int32, Sendable {
    case planeFallback = 1
    case solderMask = 10
    case overlay = 15
    case silkscreen = 20
    case decal = 22
    case text = 25
    case shadow = 27
    case keepout = 30
    case outline = 35
    case mark = 41
}

/// One mesh: interleaved positions and normals, its triangles' indices, and
/// the range of those indices each material draws.
struct BoardSceneMeshData: Sendable {
    struct Part: Sendable, Equatable {
        var indexOffset: Int
        var indexCount: Int
        var materialIndex: Int
    }

    /// Six floats a vertex: position x, y, z, then normal x, y, z.
    static let floatsPerVertex = 6

    var vertices: [Float] = []
    var indices: [UInt32] = []
    var parts: [Part] = []
    var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    var vertexCount: Int {
        vertices.count / Self.floatsPerVertex
    }

    var isEmpty: Bool {
        indices.isEmpty
    }

    var hasBounds: Bool {
        boundsMin.x <= boundsMax.x && boundsMin.y <= boundsMax.y && boundsMin.z <= boundsMax.z
    }

    func position(at index: Int) -> SIMD3<Float> {
        let base = index * Self.floatsPerVertex
        return SIMD3(vertices[base], vertices[base + 1], vertices[base + 2])
    }
}

/// Collects a mesh one vertex and triangle at a time, each triangle in one
/// of a fixed number of material slots.
struct BoardSceneMeshBuilder {
    private(set) var vertices: [Float] = []
    private var indicesBySlot: [[UInt32]]
    private var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    init(slotCount: Int) {
        indicesBySlot = Array(repeating: [], count: max(slotCount, 1))
    }

    var vertexCount: Int {
        vertices.count / BoardSceneMeshData.floatsPerVertex
    }

    var isEmpty: Bool {
        indicesBySlot.allSatisfy(\.isEmpty)
    }

    mutating func reserveVertices(_ count: Int) {
        vertices.reserveCapacity(vertices.count + count * BoardSceneMeshData.floatsPerVertex)
    }

    @discardableResult
    mutating func addVertex(_ position: SIMD3<Float>, normal: SIMD3<Float>) -> UInt32 {
        let index = UInt32(vertexCount)
        vertices.append(position.x)
        vertices.append(position.y)
        vertices.append(position.z)
        vertices.append(normal.x)
        vertices.append(normal.y)
        vertices.append(normal.z)
        boundsMin = simd_min(boundsMin, position)
        boundsMax = simd_max(boundsMax, position)
        return index
    }

    mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, slot: Int = 0) {
        indicesBySlot[slot].append(a)
        indicesBySlot[slot].append(b)
        indicesBySlot[slot].append(c)
    }

    /// A flat quad from four corners in order around it, as two triangles.
    mutating func addQuad(_ corners: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), normal: SIMD3<Float>, slot: Int = 0) {
        let a = addVertex(corners.0, normal: normal)
        let b = addVertex(corners.1, normal: normal)
        let c = addVertex(corners.2, normal: normal)
        let d = addVertex(corners.3, normal: normal)
        addTriangle(a, b, c, slot: slot)
        addTriangle(a, c, d, slot: slot)
    }

    func build() -> BoardSceneMeshData {
        var mesh = BoardSceneMeshData()
        mesh.vertices = vertices
        mesh.indices.reserveCapacity(indicesBySlot.reduce(0) { $0 + $1.count })
        for (slot, indices) in indicesBySlot.enumerated() where !indices.isEmpty {
            mesh.parts.append(BoardSceneMeshData.Part(indexOffset: mesh.indices.count, indexCount: indices.count, materialIndex: slot))
            mesh.indices.append(contentsOf: indices)
        }
        mesh.boundsMin = boundsMin
        mesh.boundsMax = boundsMax
        return mesh
    }
}

/// One mesh of the scene and how it is drawn.
struct BoardSceneMeshItem: Sendable {
    var group: BoardSceneGroup
    /// How far the item moves, per millimetre of layer separation, when the
    /// view explodes; nil for things that stay put (outlines, keepouts).
    var explodeFactor: Double?
    var name: String
    var mesh: BoardSceneMeshData
    var materials: [BoardSceneMaterialSpec]
    var role: BoardSceneMaterialRole
    var drawOrder: BoardSceneDrawOrder?
}

/// A word that always faces the camera: board names over panels, axis names.
struct BoardSceneLabel: Sendable {
    var text: String
    var position: SIMD3<Float>
    var scale: Float
    var color: BoardSceneColor
    var bold: Bool
    var group: BoardSceneGroup
}

/// A package's model: its mesh and materials, once for every placement of it.
final class BoardSceneModelAsset: Sendable {
    /// What placements share: the file, or the box a placeholder draws.
    let key: String
    let mesh: BoardSceneMeshData
    let materials: [BoardSceneMaterialSpec]

    init(key: String, mesh: BoardSceneMeshData, materials: [BoardSceneMaterialSpec]) {
        self.key = key
        self.mesh = mesh
        self.materials = materials
    }
}

/// One placed package's model.
struct BoardSceneModelPlacement: Sendable {
    /// The package's id, lowercased.
    var packageID: String
    var componentID: String?
    var group: BoardSceneGroup
    var explodeFactor: Double
    var asset: BoardSceneModelAsset
    /// From the asset's own coordinates to the unexploded scene.
    var transform: simd_float4x4
}

/// A directional light: the way it shines and how strongly.
struct BoardSceneLight: Sendable {
    var direction: SIMD3<Float>
    var intensity: Float
    /// Its shadows are drawn on the board while the view's Shadows option is
    /// on: the parts' on the face it lights.
    var castsShadow: Bool
}

/// Everything the scene shows, built off the main actor.
struct BoardSceneDescription: Sendable {
    var board: HorizontalBoard
    /// The board point at the scene's origin.
    var center: HorizontalPoint
    var boardThickness: Double
    var boardWidth: Double
    var boardDepth: Double
    var meshes: [BoardSceneMeshItem] = []
    var labels: [BoardSceneLabel] = []
    var models: [BoardSceneModelPlacement] = []
    /// Vias and plated package holes: their barrels and rings are laid out
    /// when the view's explode and plating are known.
    var vias: [HorizontalMarker] = []
    var lights: [BoardSceneLight] = []
    /// The board's body for picking: a click on it is a click on no part.
    var boardBoxMin = SIMD3<Float>(repeating: 0)
    var boardBoxMax = SIMD3<Float>(repeating: 0)
}

/// Gathers the scene's geometry into as few meshes as share a look: every
/// pad of a layer, every trace of a layer, every text of a layer is one
/// mesh, so one draw, however many there are.
struct BoardSceneMeshAccumulator {
    struct Key: Hashable {
        var group: BoardSceneGroup
        var explodeFactorMilli: Int?
        var role: BoardSceneMaterialRole
        var materials: [BoardSceneMaterialSpec]
        var drawOrder: BoardSceneDrawOrder?
        var name: String
    }

    private var order: [Key] = []
    private var builders: [Key: BoardSceneMeshBuilder] = [:]
    private var factors: [Key: Double?] = [:]

    mutating func append(
        group: BoardSceneGroup,
        explodeFactor: Double?,
        role: BoardSceneMaterialRole = .fixed,
        materials: [BoardSceneMaterialSpec],
        drawOrder: BoardSceneDrawOrder? = nil,
        name: String = "",
        _ body: (inout BoardSceneMeshBuilder) -> Void
    ) {
        let key = Key(
            group: group,
            explodeFactorMilli: explodeFactor.map { Int(($0 * 1_000).rounded()) },
            role: role,
            materials: materials,
            drawOrder: drawOrder,
            name: name
        )
        if builders[key] == nil {
            order.append(key)
            builders[key] = BoardSceneMeshBuilder(slotCount: materials.count)
            factors[key] = explodeFactor
        }
        body(&builders[key]!)
    }

    func items() -> [BoardSceneMeshItem] {
        order.compactMap { key in
            guard let builder = builders[key], !builder.isEmpty else {
                return nil
            }
            return BoardSceneMeshItem(
                group: key.group,
                explodeFactor: factors[key] ?? nil,
                name: key.name,
                mesh: builder.build(),
                materials: key.materials,
                role: key.role,
                drawOrder: key.drawOrder
            )
        }
    }
}
