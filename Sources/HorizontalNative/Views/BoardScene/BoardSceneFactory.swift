import Foundation
import HorizontalPlaneClipper
import simd

/// Where the scene puts a board's surfaces, in scene millimetres.
struct BoardSceneLayout: Equatable {
    var boardThickness: Double
    var substrateTopY: Double
    var substrateBottomY: Double
    var topCopperTopY: Double
    var bottomCopperBottomY: Double
    var topMaskBottomY: Double
    var topMaskTopY: Double
    var bottomMaskTopY: Double
    var bottomMaskBottomY: Double
    var topSilkscreenY: Double
}

/// Builds a board's 3D scene as plain meshes, off the main actor. The scene
/// is in millimetres, y up, with the board's centre at the origin: board x
/// stays x and board y becomes -z.
enum BoardSceneFactory {
    static let unitsPerMillimeter = 1_000_000.0
    static let boardTopHeight = 0.5
    private static let fallbackBoardThickness = 0.8
    /// Vertical clearance between a component model and the nearest board face,
    /// in millimetres. Mirrors Horizon's `BOARD_OFFSET` so models do not
    /// z-fight with the board.
    private static let modelBoardClearance = 0.05
    private static let copperVisualThickness = 0.06
    private static let solderMaskThickness = 0.03
    private static let solderPasteThickness = 0.035
    /// The clearance between a layer's face and the face of the layer it
    /// sits on (mask over copper, silkscreen over mask). Two faces closer
    /// than the depth buffer can tell apart draw as a flickering mesh of
    /// each other's triangles; ten microns is well clear at any zoom the
    /// camera's clipping planes allow, and invisible.
    private static let layerSurfaceGap = 0.01
    private static let maximumPlaneFragments = 400

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
        func color(for layer: Int?) -> BoardSceneColor {
            BoardSceneColor(HorizontalDefaultTheme.nsLayerColor(for: layer))
        }

        func padColor(for layer: Int?) -> BoardSceneColor {
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
        var holes = true
        var originAxes = false
        var orientationAxes = false
        var silkscreenClipping: HorizontalSilkscreenClipping? = nil

        static let full = BuildOptions()
    }

    /// What the scene is being built from, handed to every stage.
    private struct Build {
        var board: HorizontalBoard
        var center: HorizontalPoint
        var boardThickness: Double
        var meshes = BoardSceneMeshAccumulator()
        var labels: [BoardSceneLabel] = []
        var models: [BoardSceneModelPlacement] = []
        var materialPalette = MaterialPalette()
    }

    /// Builds and discards a full scene: for measuring the build itself.
    static func measureSceneBuild(for board: HorizontalBoard) {
        _ = describeScene(for: board, options: .full)
    }

    /// The barrels the board's plated package holes get, for tests: a
    /// marker per hole, sized to the round pad it replaces or, in any other
    /// pad, to the hole alone.
    static func packageViaMarkers(for board: HorizontalBoard) -> [(marker: HorizontalMarker, coveredPadIDs: Set<String>)] {
        packageViaRenderInfo(for: board).map { ($0.marker, $0.coveredPadIDs) }
    }

    /// How many meshes the full scene's silkscreen holds, for tests.
    static func silkscreenGeometryCount(for board: HorizontalBoard) -> Int {
        describeScene(for: board, options: .full).meshes.filter { $0.group == .silkscreen && !$0.mesh.isEmpty }.count
    }

    /// The heights the scene places a board's surfaces at, for tests.
    static func sceneLayout(for board: HorizontalBoard) -> BoardSceneLayout {
        let thickness = boardBodyThickness(for: board)
        let topMaskTop = solderMaskTopSurfaceHeight(for: HorizontalBoardLayers.topMask, board: board, boardThickness: thickness)
        let bottomMaskTop = solderMaskTopSurfaceHeight(for: HorizontalBoardLayers.bottomMask, board: board, boardThickness: thickness)
        return BoardSceneLayout(
            boardThickness: thickness,
            substrateTopY: boardTopHeight,
            substrateBottomY: boardTopHeight - dielectricThickness(for: board, fallback: thickness),
            topCopperTopY: copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: thickness),
            bottomCopperBottomY: copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: thickness),
            topMaskBottomY: topMaskTop - solderMaskThickness,
            topMaskTopY: topMaskTop,
            bottomMaskTopY: bottomMaskTop,
            bottomMaskBottomY: bottomMaskTop - solderMaskThickness,
            topSilkscreenY: silkscreenSurfaceHeight(for: HorizontalBoardLayers.topSilkscreen, board: board, boardThickness: thickness) ?? 0
        )
    }

    /// Receives (stage, milliseconds) for every stage of a scene build.
    nonisolated(unsafe) static var stageTimingSink: ((String, Double) -> Void)?

    static func stage<T>(_ label: String, _ body: () -> T) -> T {
        guard let stageTimingSink else {
            return body()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        stageTimingSink(label, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        return result
    }

    /// The board's scene, as meshes ready to become entities.
    static func describeScene(for board: HorizontalBoard, silkscreenClipping: HorizontalSilkscreenClipping? = nil) -> BoardSceneDescription {
        var options = BuildOptions.full
        options.silkscreenClipping = silkscreenClipping
        return describeScene(for: board, options: options)
    }

    private static func describeScene(for board: HorizontalBoard, options: BuildOptions) -> BoardSceneDescription {
        // A package's Omit Silkscreen and Omit Outline leave its own artwork
        // out, as on the board and in the exports.
        let board = board.omittingPackageArtwork()
        let bodyBounds = board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds
        let center = bodyBounds.center
        let width = max(bodyBounds.width / unitsPerMillimeter, 10)
        let depth = max(bodyBounds.height / unitsPerMillimeter, 10)
        let thickness = boardBodyThickness(for: board)
        var build = Build(board: board, center: center, boardThickness: thickness)

        let boardColors = HorizontalBoardColors(
            silkscreen: board.colors.silkscreen,
            solderMask: board.colors.solderMask,
            substrate: board.colors.substrate
        )
        stage("substrate") {
            addSubstrate(to: &build, width: width, depth: depth, colors: boardColors)
        }
        stage("solder mask") {
            addSolderMaskSlabs(to: &build, width: width, depth: depth, colors: boardColors, includeOpenings: options.solderMaskOpenings)
        }

        addBoardPanelOutlines(board.boardPanels, to: &build)
        let silkscreenClips = stage("silkscreen clipping") { options.silkscreenClipping.map { clipping in
            HorizontalSilkscreenClipper.clip(board: board, clipping: clipping)
        } ?? [:] }
        if options.layerArtwork {
            stage("planes") { addPlanes(board.planes, to: &build) }
            stage("keepouts") { addKeepouts(board.keepouts, to: &build) }
            stage("board artwork") {
                addCategorizedArtwork(
                    board.polygons.filter { !isBoardBodyLayer($0.layer) }, lines: board.lines, arcs: board.arcs, to: &build,
                    polygonOpacity: 0.34, lineOpacity: 0.58, polygonYOffset: 0.02, lineYOffset: 0.03, silkscreenClips: silkscreenClips
                )
            }
            stage("package artwork") {
                addCategorizedArtwork(
                    board.packagePolygons, lines: board.packageLines, arcs: board.packageArcs, to: &build,
                    polygonOpacity: 0.28, lineOpacity: 0.62, polygonYOffset: 0.04, lineYOffset: 0.05, silkscreenClips: silkscreenClips
                )
            }
        }

        if options.decals {
            stage("decals") { addDecals(board.decals, to: &build) }
        }

        if options.texts {
            stage("texts") {
                addCategorizedTexts(board.texts, to: &build, silkscreenClips: silkscreenClips)
                addCategorizedTexts(board.packageTexts, to: &build, silkscreenClips: silkscreenClips)
            }
        }

        if options.placedModels {
            stage("models") { addPackages(to: &build) }
        }
        if options.placeholderPackages {
            stage("placeholders") { addPackagePlaceholders(to: &build, onlyMissingModels: options.placedModels) }
        }

        let packageVias = stage("package vias") { packageViaRenderInfo(for: board) }
        let packageViaPadIDs = Set(packageVias.flatMap(\.coveredPadIDs))
        if options.packagePads {
            stage("pads") { addPads(board.packagePads, to: &build, excludingPadIDs: packageViaPadIDs) }
        }

        if options.tracks {
            stage("tracks") { addCopperTraceGeometry(board.tracks + board.netTies, to: &build) }
        }

        if options.originAxes {
            addBoardOriginAxes(to: &build, width: width, depth: depth)
        }
        if options.orientationAxes {
            addOrientationAxes(to: &build, width: width, depth: depth)
        }

        var scene = BoardSceneDescription(
            board: board,
            center: center,
            boardThickness: thickness,
            boardWidth: width,
            boardDepth: depth
        )
        scene.meshes = stage("meshes") { build.meshes.items() }
        scene.labels = build.labels
        scene.models = build.models
        if options.holes {
            // Drilled holes are the cutouts through the substrate, copper and
            // mask; nothing is drawn in the void itself (the via and
            // through-hole barrels are copper and live with the vias). Every
            // via is drawn: its barrel and rings are instances of a handful
            // of meshes, so a thousand more cost a thousand transforms.
            scene.vias = board.vias + packageVias.map(\.marker)
        }
        scene.lights = lights(width: width, depth: depth)
        let halfWidth = Float(bodyBounds.isEmpty ? width / 2 : bodyBounds.width / unitsPerMillimeter / 2)
        let halfDepth = Float(bodyBounds.isEmpty ? depth / 2 : bodyBounds.height / unitsPerMillimeter / 2)
        scene.boardBoxMin = SIMD3(-halfWidth, Float(boardTopHeight - thickness), -halfDepth)
        scene.boardBoxMax = SIMD3(halfWidth, Float(boardTopHeight), halfDepth)
        return scene
    }

    static func explodeFactor(
        for layer: Int?,
        board: HorizontalBoard,
        boardThickness: Double
    ) -> Double {
        guard let layer else { return 1.0 }

        let centerY = boardTopHeight - boardThickness / 2
        let halfThickness = max(boardThickness / 2, 0.001)

        if HorizontalBoardLayers.isCopper(layer) {
            let layerY = copperHeight(for: layer, board: board, boardThickness: boardThickness)
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

    private static func groupForCategory(_ layer: Int?) -> BoardSceneGroup {
        guard let layer else { return .copper }
        switch HorizontalBoardLayers.category(for: layer) {
        case .silkscreen: return .silkscreen
        case .solderMask: return .solderMask
        case .paste: return .paste
        default: return .copper
        }
    }

    /// Copper of a copper layer follows the copper colour; anything else
    /// keeps the colour it was built with.
    private static func copperRole(for layer: Int?) -> BoardSceneMaterialRole {
        guard let layer, HorizontalBoardLayers.isCopper(layer) else {
            return .fixed
        }
        return .copper(layer: layer)
    }

    // MARK: Substrate and mask

    private static func addSubstrate(to build: inout Build, width: Double, depth: Double, colors: HorizontalBoardColors) {
        let board = build.board
        let boardThickness = build.boardThickness
        let descending = board.stackupLayers.sorted { $0.layer > $1.layer }
        let dielectricLayers = descending.filter {
            $0.substrateThickness > 0 && $0.layer != HorizontalBoardLayers.bottomCopper
        }

        // Every drilled hole — free, via or package — comes out of the
        // substrate, so a through-hole part's pins show as holes, not as
        // pads sitting on solid board.
        let drillCutouts = drillCutoutPaths(for: nil, board: board)

        // One footprint per piece of board, extruded once per dielectric
        // layer; the cutouts drawn on the outline layer come out of it. A
        // board without an outline is a rectangle the size of its contents.
        var templates = HorizontalBoardOutlines.shapes(from: board.polygons).compactMap {
            boardBodyTemplate(for: $0.outer, cutouts: drillCutouts + $0.cutouts)
        }
        if templates.isEmpty, let rectangle = boardBodyTemplate(for: rectangle(width: width, depth: depth, center: build.center), cutouts: []) {
            templates = [rectangle]
        }

        let substrateColor = colors.substrate.map(BoardSceneColor.init)
            ?? BoardSceneColor(HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.outline))
        let materials = [
            BoardSceneMaterialSpec(color: substrateColor.opaque, roughness: 0.85),
            BoardSceneMaterialSpec(color: substrateColor.opaque, roughness: 0.9),
        ]

        var slabs: [(thickness: Double, topY: Double)] = []
        if dielectricLayers.count <= 1 {
            slabs = [(dielectricThickness(for: board, fallback: boardThickness), boardTopHeight)]
        } else {
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
                slabs.append((min(max(slabThickness, 0.05), 6.0), y))
                y -= slabThickness
            }
        }

        let boardCenterY = boardTopHeight - boardThickness / 2
        let halfThickness = max(boardThickness / 2, 0.001)
        for slab in slabs {
            let midY = slab.topY - slab.thickness / 2
            let factor = (midY - boardCenterY) / halfThickness
            build.meshes.append(group: .substrate, explodeFactor: factor, role: .substrate, materials: materials, name: "substrate") { builder in
                for template in templates {
                    stage("substrate: mesh") {
                        appendExtruded(template, center: build.center, thickness: slab.thickness, topY: slab.topY, faceSlot: 0, wallSlot: 1, to: &builder)
                    }
                }
            }
        }
    }

    private static func rectangle(width: Double, depth: Double, center: HorizontalPoint) -> HorizontalPolygon {
        let halfWidth = width * unitsPerMillimeter / 2
        let halfDepth = depth * unitsPerMillimeter / 2
        return HorizontalPolygon(
            id: "board-rectangle",
            vertices: [
                HorizontalPoint(x: center.x - halfWidth, y: center.y - halfDepth),
                HorizontalPoint(x: center.x + halfWidth, y: center.y - halfDepth),
                HorizontalPoint(x: center.x + halfWidth, y: center.y + halfDepth),
                HorizontalPoint(x: center.x - halfWidth, y: center.y + halfDepth),
            ],
            layer: nil
        )
    }

    private static func addSolderMaskSlabs(
        to build: inout Build,
        width: Double,
        depth: Double,
        colors: HorizontalBoardColors,
        includeOpenings: Bool = true
    ) {
        let board = build.board
        let boardThickness = build.boardThickness
        let center = build.center
        let maskColor = colors.solderMask.map(BoardSceneColor.init)
            ?? BoardSceneColor(HorizontalDefaultTheme.nsLayerColor(for: HorizontalBoardLayers.topMask))
        var shapes = HorizontalBoardOutlines.shapes(from: board.polygons).map { (outer: $0.outer, cutouts: $0.cutouts) }
        if shapes.isEmpty {
            shapes = [(rectangle(width: width, depth: depth, center: center), [])]
        }
        // The pad outlines serve both mask layers; unioning seven thousand
        // pads is worth doing once.
        let padFragments = includeOpenings ? horizonPadOutlineFragments(board.packagePads) : []

        // The mask sits just outside the copper face it covers: over the top
        // copper on top, under the bottom copper below.
        let topY = solderMaskTopSurfaceHeight(for: HorizontalBoardLayers.topMask, board: board, boardThickness: boardThickness)
        let bottomY = solderMaskTopSurfaceHeight(for: HorizontalBoardLayers.bottomMask, board: board, boardThickness: boardThickness)
        let material = solderMaskMaterial(color: maskColor)

        for (slabTopY, layer) in [(topY, HorizontalBoardLayers.topMask), (bottomY, HorizontalBoardLayers.bottomMask)] {
            let openings = stage("mask: openings") { includeOpenings ? solderMaskOpenings(for: layer, board: board, padFragments: padFragments) : [] }
            let factor = explodeFactor(for: layer, board: board, boardThickness: boardThickness)
            build.meshes.append(group: .solderMask, explodeFactor: factor, role: .solderMask, materials: [material], drawOrder: .solderMask, name: "mask:\(layer)") { builder in
                for shape in shapes {
                    let outlineOpenings = stage("mask: filter") { openings
                        .filter { solderMaskOpening($0, intersects: shape.outer) }
                        .flatMap(\.paths) }
                    let fragments = outlineFragments(for: shape.outer, cutouts: outlineOpenings + shape.cutouts)
                    guard !fragments.isEmpty else {
                        continue
                    }
                    let template = ExtrudedMeshTemplate(fragments)
                    guard !template.isEmpty else {
                        continue
                    }
                    stage("mask: mesh") {
                        appendExtruded(template, center: center, thickness: solderMaskThickness, topY: slabTopY, faceSlot: 0, wallSlot: 0, to: &builder)
                    }
                }
            }
        }
    }

    private static func solderMaskMaterial(color: BoardSceneColor) -> BoardSceneMaterialSpec {
        // Single-sided: the slab's underside lies a hair above the copper it
        // covers, and drawing it too meant two translucent faces (double the
        // tint) and a depth fight with the copper's top face.
        BoardSceneMaterialSpec(color: color.opaque, roughness: 0.6, opacity: 0.7, doubleSided: false)
    }

    private static func solderMaskOpenings(
        for layer: Int,
        board: HorizontalBoard,
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
            let line = segment(for: arc)
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

    // MARK: Panels

    private static func addBoardPanelOutlines(_ panels: [HorizontalBoardPanel], to build: inout Build) {
        let overlay = BoardSceneColor(HorizontalDefaultTheme.textOverlayNS)
        let material = BoardSceneMaterialSpec(color: overlay.opaque, emission: overlay.withAlpha(0.08), opacity: 0.42)
        let center = build.center

        for panel in panels where !panel.bounds.isEmpty {
            let y = boardTopHeight + 0.22
            let corners = [
                HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.minY),
                HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.minY),
                HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.maxY),
                HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.maxY)
            ].map { scenePoint($0, center: center, y: y) }

            build.meshes.append(group: .outline, explodeFactor: nil, materials: [material], drawOrder: .outline, name: "panels") { builder in
                for index in corners.indices {
                    appendCylinder(from: corners[index], to: corners[(index + 1) % corners.count], radius: 0.018, to: &builder)
                }
            }

            if !panel.boardName.isEmpty {
                build.labels.append(BoardSceneLabel(
                    text: panel.boardName,
                    position: scenePoint(panel.bounds.center, center: center, y: boardTopHeight + 0.7),
                    scale: 0.22,
                    color: overlay.withAlpha(0.62),
                    bold: false,
                    group: .panelLabel
                ))
            }
        }
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
        // A substrate entry on the bottom copper would lie below the board;
        // Horizon writes it as zero and `totalSubstrateThickness` (which the
        // substrate slab is built from) ignores it, so the board's depth must
        // too, or the bottom-side layers float a slab's worth below it.
        let total = layers.reduce(0.0) { partial, layer in
            partial
                + max(layer.copperThickness / unitsPerMillimeter, 0)
                + (layer.layer == HorizontalBoardLayers.bottomCopper ? 0 : max(layer.substrateThickness / unitsPerMillimeter, 0))
        } - topCopper
        return max(total, board.totalSubstrateThickness / unitsPerMillimeter)
    }

    private static func dielectricThickness(for board: HorizontalBoard, fallback: Double) -> Double {
        let thickness = board.totalSubstrateThickness / unitsPerMillimeter
        return thickness > 0 ? thickness : fallback
    }

    static func copperThickness(
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

    // MARK: Packages

    private static func addPackages(to build: inout Build) {
        let board = build.board
        for package in board.packages {
            guard let model = package.model3D else {
                continue
            }
            let packageColor = package.mirrored
                ? build.materialPalette.color(for: HorizontalBoardLayers.bottomCopper)
                : build.materialPalette.color(for: HorizontalBoardLayers.topCopper)
            guard let asset = BoardSceneModelLibrary.shared.asset(for: model, fallbackColor: packageColor) else {
                continue
            }
            // Lift the component clear of the board face. The model's package-local
            // x/y/z offset is applied before the board placement transform,
            // matching Horizon's model shader.
            let surfaceY = package.mirrored
                ? copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: build.boardThickness) - modelBoardClearance
                : copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: build.boardThickness) + modelBoardClearance
            let root = simd_float4x4(translation: scenePoint(package.position, center: build.center, y: surfaceY))
            let transform = root * modelBoardPlacementTransform(for: package) * modelLocalTransform(for: model)
            build.models.append(BoardSceneModelPlacement(
                packageID: package.id.lowercased(),
                componentID: package.componentID,
                group: package.componentDetails?.noPopulate == true ? .noPopulateModel : .model,
                explodeFactor: package.mirrored ? -3.0 : 3.0,
                asset: asset,
                transform: transform
            ))
        }
    }

    private static func addPackagePlaceholders(to build: inout Build, onlyMissingModels: Bool) {
        let board = build.board
        for package in board.packages {
            if onlyMissingModels && package.model3D != nil {
                continue
            }
            let footprintBounds = packageFootprintBounds(for: package.id, board: board)
            let fallbackSize = 2.2
            let footprintWidth = footprintBounds.map { max($0.width / unitsPerMillimeter, 0.8) } ?? fallbackSize
            let footprintDepth = footprintBounds.map { max($0.height / unitsPerMillimeter, 0.8) } ?? fallbackSize
            let height = componentHeight(width: footprintWidth, depth: footprintDepth)
            let packageColor = package.mirrored
                ? build.materialPalette.color(for: HorizontalBoardLayers.bottomCopper)
                : build.materialPalette.color(for: HorizontalBoardLayers.topCopper)
            let size = SIMD3(Float(footprintWidth), Float(height), Float(footprintDepth))
            let asset = BoardSceneModelLibrary.shared.boxAsset(
                size: size,
                materials: [BoardSceneMaterialSpec(color: packageColor.opaque, roughness: 0.8, opacity: 0.42)]
            )

            let packageCenter = footprintBounds?.center ?? package.position
            let clearance = 0.24
            let surfaceY = package.mirrored
                ? copperOuterSurfaceHeight(forTopSide: false, board: board, boardThickness: build.boardThickness)
                : copperOuterSurfaceHeight(forTopSide: true, board: board, boardThickness: build.boardThickness)
            let yPosition = package.mirrored
                ? surfaceY - clearance - height / 2
                : surfaceY + clearance + height / 2
            build.models.append(BoardSceneModelPlacement(
                packageID: package.id.lowercased(),
                componentID: package.componentID,
                group: .placeholderModel,
                explodeFactor: package.mirrored ? -3.0 : 3.0,
                asset: asset,
                transform: simd_float4x4(translation: scenePoint(packageCenter, center: build.center, y: yPosition))
            ))
        }
    }

    // Horizon's face vertex shader: `rot = R(x, roll) * R(y, pitch) * R(z, yaw)`
    // applied to column vectors, so the yaw turns the mesh first, the pitch
    // second and the roll last, and only then is the package-local x/y/z
    // offset added, unrotated. (Its `rotationMatrix` fills GLSL's
    // column-major mat4 with a row-major rotation, which turns by the
    // negated angle; the signs below fold that in together with the z-up to
    // y-up axis swap: Horizon y is scene -z, Horizon z is scene y.)
    // Parts with two rotations — a pitch and a yaw — land wrongly when any
    // of this is composed the other way round.
    static func modelLocalTransform(for model: HorizontalPackage3DModel) -> simd_float4x4 {
        let roll = simd_float4x4(rotationAbout: SIMD3(1, 0, 0), angle: -angleRadians(model.roll))
        let pitch = simd_float4x4(rotationAbout: SIMD3(0, 0, 1), angle: angleRadians(model.pitch))
        let yaw = simd_float4x4(rotationAbout: SIMD3(0, 1, 0), angle: -angleRadians(model.yaw))
        let offset = SIMD3(
            Float(model.x / unitsPerMillimeter),
            Float(model.z / unitsPerMillimeter),
            Float(-model.y / unitsPerMillimeter)
        )
        return simd_float4x4(translation: offset) * roll * pitch * yaw
    }

    private static func modelBoardPlacementTransform(for package: HorizontalPlacement) -> simd_float4x4 {
        let rotation = simd_float4x4(rotationAbout: SIMD3(0, 1, 0), angle: angleRadians(package.angle))
        if package.mirrored {
            // Over onto the board's underside first, then turned.
            return rotation * simd_float4x4(rotationAbout: SIMD3(0, 0, 1), angle: .pi)
        }
        return rotation
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

    private static func angleRadians(_ angle: Int) -> Float {
        Float(Double(angle) / 65_536.0 * Double.pi * 2)
    }

    private static func normalizedID(_ id: String) -> String {
        id.lowercased()
    }

    // MARK: Pads

    private static func addPads(
        _ pads: [HorizontalPolygon],
        to build: inout Build,
        excludingPadIDs: Set<String> = []
    ) {
        let renderPads = pads.filter {
            !excludingPadIDs.contains($0.id)
                && !isExcludedFrom3DScene($0.layer)
                && !isSolderMaskLayer($0.layer)
        }
        let board = build.board
        // A pad's own drilled holes come out of its copper; a hole drilled
        // elsewhere on the board that lands inside the pad does too.
        let packageHolesByPadID = Dictionary(grouping: board.packageHoles) { packagePadID(for: $0.id) ?? $0.id }
        let otherHoles = board.holes + board.viaHoles
        // Every pad of a layer goes into one mesh: a node per pad was a
        // draw call per pad.
        var fragmentsByLayer = [Int: [[[HorizontalPoint]]]]()
        var layerOrder = [Int]()
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
            var fragments = [pad.paths]
            if !cutouts.isEmpty {
                fragments = clippedSceneFragments(subjects: pad.paths, cutouts: cutouts)
                guard !fragments.isEmpty else {
                    // The hole swallowed the pad: nothing left to render.
                    continue
                }
            }
            let layerKey = pad.layer ?? Int.min
            if fragmentsByLayer[layerKey] == nil {
                layerOrder.append(layerKey)
            }
            fragmentsByLayer[layerKey, default: []].append(contentsOf: fragments)
        }
        for layerKey in layerOrder {
            let layer: Int? = layerKey == Int.min ? nil : layerKey
            let padColor = build.materialPalette.padColor(for: layer)
            let materials: [BoardSceneMaterialSpec]
            if let layer, HorizontalBoardLayers.category(for: layer) == .paste {
                materials = [.paste(padColor), .paste(padColor)]
            } else if let layer, HorizontalBoardLayers.isCopper(layer) {
                var side = BoardSceneMaterialSpec.copper(padColor)
                side.roughness = 0.28
                materials = [.copper(padColor), side]
            } else {
                materials = [
                    BoardSceneMaterialSpec(color: padColor.opaque, roughness: 0.55, doubleSided: true),
                    BoardSceneMaterialSpec(color: padColor.opaque, roughness: 0.65, doubleSided: true),
                ]
            }
            let thickness = padExtrusionDepth(for: layer, board: board)
            let centerY = padTopSurfaceHeight(for: layer, board: board, boardThickness: build.boardThickness)
            let center = build.center
            build.meshes.append(
                group: groupForCategory(layer),
                explodeFactor: explodeFactor(for: layer, board: board, boardThickness: build.boardThickness),
                role: copperRole(for: layer),
                materials: materials,
                name: "layer:\(layer ?? -1)"
            ) { builder in
                appendExtruded(fragmentsByLayer[layerKey] ?? [], center: center, thickness: thickness, centerY: centerY, to: &builder)
            }
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

            let padLayers = Set(copperPads.compactMap(\.layer).filter(HorizontalBoardLayers.isCopper))
            let connectedLayers = padLayers.count >= 2
                ? padLayers.sorted(by: >)
                : defaultConnectedLayers
            // A round pad is replaced by a ring around the barrel. Any other
            // pad (an obround with two drills, say) keeps its own copper and
            // gets just the plated barrel: a marker no wider than its hole
            // draws no ring.
            let outerDiameter: Double
            if let padDiameter = roundPads.map(\.diameter).max() {
                outerDiameter = max(padDiameter, hole.diameter * 1.25)
            } else {
                outerDiameter = hole.diameter
            }
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

    // MARK: Artwork

    private static func addCategorizedArtwork(
        _ polygons: [HorizontalPolygon],
        lines: [HorizontalSegment],
        arcs: [HorizontalArc] = [],
        to build: inout Build,
        polygonOpacity: Double,
        lineOpacity: Double,
        polygonYOffset: Double,
        lineYOffset: Double,
        silkscreenClips: [Int: HorizontalClippedSilkscreenLayer] = [:]
    ) {
        let board = build.board
        for polygon in polygons where !isExcludedFrom3DScene(polygon.layer) && !isPackageOrAssemblyLayer(polygon.layer) && !isSolderMaskLayer(polygon.layer) {
            if let layer = polygon.layer, let clipped = silkscreenClips[layer]?.object(polygon.id) {
                addClippedSilkscreen(
                    clipped, layer: layer, to: &build, opacity: 0.72,
                    height: overlayHeight(for: layer, board: board, boardThickness: build.boardThickness) + overlayArtworkYOffset(for: layer, fallback: polygonYOffset)
                )
                continue
            }
            let effectiveOpacity: Double
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
            let group = groupForCategory(polygon.layer)
            appendOverlayPolygon(
                polygon,
                group: group,
                role: group == .silkscreen ? .silkscreen : .fixed,
                drawOrder: group == .silkscreen ? .silkscreen : .overlay,
                to: &build,
                opacity: effectiveOpacity,
                yOffset: effectiveYOffset
            )
        }

        // Every line and arc of a layer becomes one mesh: the strokes
        // unioned, so joints neither double up nor cost a node each.
        var lineCapsulesByLayer = [Int: [[HorizontalPoint]]]()
        var lineLayerOrder = [Int]()
        let strokes = lines + arcs.map(segment(for:))
        for line in strokes where !isExcludedFrom3DScene(line.layer) && !isPackageOrAssemblyLayer(line.layer) && !isSolderMaskLayer(line.layer) {
            if let layer = line.layer, let clipped = silkscreenClips[layer]?.object(line.id) {
                addClippedSilkscreen(
                    clipped, layer: layer, to: &build, opacity: 0.82,
                    height: overlayHeight(for: layer, board: board, boardThickness: build.boardThickness) + overlayArtworkYOffset(for: layer, fallback: lineYOffset)
                )
                continue
            }
            let layerKey = line.layer ?? Int.min
            if lineCapsulesByLayer[layerKey] == nil {
                lineLayerOrder.append(layerKey)
            }
            lineCapsulesByLayer[layerKey, default: []].append(contentsOf: traceClosedPaths(line))
        }
        for layerKey in lineLayerOrder {
            let layer: Int? = layerKey == Int.min ? nil : layerKey
            let effectiveOpacity: Double
            if let layer {
                switch HorizontalBoardLayers.category(for: layer) {
                case .silkscreen: effectiveOpacity = 0.82
                case .solderMask: effectiveOpacity = 0.72
                default: effectiveOpacity = lineOpacity
                }
            } else {
                effectiveOpacity = lineOpacity
            }
            let group = groupForCategory(layer)
            appendOverlayLines(
                fragments: unionedStrokeFragments(lineCapsulesByLayer[layerKey] ?? []),
                layer: layer,
                group: group,
                role: group == .silkscreen ? .silkscreen : .fixed,
                drawOrder: group == .silkscreen ? .silkscreen : .overlay,
                to: &build,
                opacity: effectiveOpacity,
                yOffset: overlayArtworkYOffset(for: layer, fallback: lineYOffset)
            )
        }
    }

    /// Silkscreen clipped to the solder mask: what is left of an object, as
    /// thin fills in the silkscreen group, in place of its strokes.
    private static func addClippedSilkscreen(
        _ clipped: HorizontalClippedSilkscreenObject,
        layer: Int,
        to build: inout Build,
        opacity: Double,
        height: Double
    ) {
        let color = build.materialPalette.color(for: layer)
        let material = BoardSceneMaterialSpec.overlay(color, opacity: opacity, emission: 0.12, roughness: 0.66)
        let center = build.center
        // One flat sheet for the whole object. An extruded solid a few
        // microns thick z-fights its own back face once it is translucent,
        // and every triangle where the back face wins blends twice — the
        // triangulation shows through. A single layer of non-overlapping
        // triangles blends once everywhere, like the mask and copper slabs.
        build.meshes.append(
            group: .silkscreen,
            explodeFactor: explodeFactor(for: layer, board: build.board, boardThickness: build.boardThickness),
            role: .silkscreen,
            materials: [material],
            drawOrder: .silkscreen,
            name: "clipped:\(layer)"
        ) { builder in
            appendFlat(clipped.fragments, center: center, y: height, facingUp: !isBottomSideLayer(layer), to: &builder)
        }
    }

    // MARK: Planes

    private static func addPlanes(_ planes: [HorizontalPlane], to build: inout Build) {
        let board = build.board
        // The drills through a layer, once per layer: every plane on it is cut
        // by the same holes.
        var drillCutoutsByLayer = [Int: [[HorizontalPoint]]]()
        for plane in planes where !isExcludedFrom3DScene(plane.layer) {
            let layerKey = plane.layer ?? Int.min
            let drillCutouts: [[HorizontalPoint]]
            if let cached = drillCutoutsByLayer[layerKey] {
                drillCutouts = cached
            } else {
                drillCutouts = drillCutoutPaths(for: plane.layer, board: board)
                drillCutoutsByLayer[layerKey] = drillCutouts
            }
            let isFallback = plane.fragments.isEmpty
            let planeColor = build.materialPalette.color(for: plane.layer)
            var face = BoardSceneMaterialSpec.copper(planeColor, writesDepth: !isFallback)
            face.roughness = isFallback ? 0.32 : 0.22
            var side = BoardSceneMaterialSpec.copper(planeColor, writesDepth: !isFallback)
            side.roughness = isFallback ? 0.36 : 0.26
            let depth = max(copperThickness(for: plane.layer, board: board), 0.004)
            let topY = planeHeight(for: plane.layer, board: board, boardThickness: build.boardThickness) + depth / 2
            let center = build.center
            // Every fragment of every plane of a layer is one mesh.
            build.meshes.append(
                group: .plane,
                explodeFactor: explodeFactor(for: plane.layer, board: board, boardThickness: build.boardThickness),
                role: copperRole(for: plane.layer),
                materials: [face, side],
                drawOrder: isFallback ? .planeFallback : nil,
                name: "layer:\(plane.layer ?? -1)"
            ) { builder in
                for fragment in plane.renderFragments.prefix(maximumPlaneFragments) {
                    // Thermal reliefs make plane holes large next to a tile, so
                    // tiling multiplies their points; one earcut per fragment is
                    // cheaper here.
                    let fragments = planeSceneFragments(fragment, drillCutouts: drillCutouts)
                    guard !fragments.isEmpty else {
                        continue
                    }
                    let template = ExtrudedMeshTemplate(SlabFragments(fragments: fragments))
                    guard !template.isEmpty else {
                        continue
                    }
                    appendExtruded(template, center: center, thickness: depth, topY: topY, faceSlot: 0, wallSlot: 1, to: &builder)
                }
            }
        }
    }

    /// A plane's poured copper with the drills through it taken out. The
    /// pour treats a plated hole as copper to connect to — its fill and its
    /// thermal spokes run straight across the hole — while the board has a
    /// hole there. Only drills whose bounds meet the fragment's are clipped;
    /// the fragment's own holes (thermal gaps, clearances) pass through.
    static func planeSceneFragments(
        _ fragment: HorizontalPlaneFragment,
        drillCutouts: [[HorizontalPoint]]
    ) -> [[[HorizontalPoint]]] {
        guard let outer = fragment.paths.first else {
            return []
        }
        let bounds = HorizontalRect(points: outer)
        let drills = drillCutouts.filter { bounds.intersects(HorizontalRect(points: $0)) }
        guard !drills.isEmpty else {
            return [fragment.paths]
        }
        return clippedSceneFragments(subjects: [outer], cutouts: Array(fragment.paths.dropFirst()) + drills)
    }

    // MARK: Tracks

    private static func addCopperTraceGeometry(_ traces: [HorizontalSegment], to build: inout Build) {
        let board = build.board
        let tracesByLayer = Dictionary(grouping: traces.filter { !isExcludedFrom3DScene($0.layer) }) {
            $0.layer ?? Int.min
        }

        for layerKey in tracesByLayer.keys.sorted() {
            let layer = layerKey == Int.min ? nil : layerKey
            let subjects = (tracesByLayer[layerKey] ?? []).flatMap { traceClosedPaths($0) }
            guard !subjects.isEmpty else {
                continue
            }

            let cutouts = drillCutoutPaths(for: layer, board: board)
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

            let color = build.materialPalette.color(for: layer)
            var side = BoardSceneMaterialSpec.copper(color)
            side.roughness = 0.28
            let thickness = copperThickness(for: layer, board: board)
            let centerY = copperHeight(for: layer, board: board, boardThickness: build.boardThickness)
            let center = build.center
            build.meshes.append(
                group: .copper,
                explodeFactor: explodeFactor(for: layer, board: board, boardThickness: build.boardThickness),
                role: copperRole(for: layer),
                materials: [.copper(color), side],
                name: "layer:\(layer ?? -1)"
            ) { builder in
                appendExtruded(pathsToRender, center: center, thickness: thickness, centerY: centerY, to: &builder)
            }
        }
    }

    // MARK: Decals, keepouts, texts

    private static func addDecals(_ decals: [HorizontalBoardDecal], to build: inout Build) {
        for decal in decals {
            for polygon in decal.polygons where !isExcludedFrom3DScene(polygon.layer) {
                appendOverlayPolygon(
                    polygon, group: .decal, role: .fixed, drawOrder: .decal, to: &build,
                    opacity: isSilkscreenLayer(polygon.layer) ? 1 : 0.58, yOffset: 0
                )
            }

            let decalStrokes = decal.lines + decal.arcs.map(segment(for:))
            for line in decalStrokes where !isExcludedFrom3DScene(line.layer) {
                appendOverlayLines(
                    fragments: unionedStrokeFragments(traceClosedPaths(line)),
                    layer: line.layer, group: .decal, role: .fixed, drawOrder: .decal, to: &build,
                    opacity: isSilkscreenLayer(line.layer) ? 1 : 0.62, yOffset: 0
                )
            }

            addCategorizedTexts(decal.texts, to: &build)
        }
    }

    private static func addKeepouts(_ keepouts: [HorizontalKeepout], to build: inout Build) {
        let red = BoardSceneColor(red: 1, green: 0, blue: 0)
        let material = BoardSceneMaterialSpec(color: red, roughness: 0.68, emission: red.withAlpha(0.08), opacity: 0.32, doubleSided: true)
        let center = build.center
        let boardThickness = build.boardThickness
        build.meshes.append(group: .keepout, explodeFactor: nil, materials: [material], drawOrder: .keepout, name: "keepouts") { builder in
            for keepout in keepouts {
                appendExtruded(
                    polygonFragments(keepout.polygon.renderVertices(arcPrecision: 32)),
                    center: center,
                    thickness: 0.01,
                    centerY: overlayHeight(for: keepout.polygon.layer, boardThickness: boardThickness) + 0.015,
                    faceSlot: 0,
                    wallSlot: 0,
                    to: &builder
                )
            }
        }
    }

    private static func addCategorizedTexts(
        _ texts: [HorizontalText],
        to build: inout Build,
        silkscreenClips: [Int: HorizontalClippedSilkscreenLayer] = [:]
    ) {
        let board = build.board
        for text in texts where !text.text.isEmpty && !isExcludedFrom3DScene(text.layer) && !isPackageOrAssemblyLayer(text.layer) {
            if let layer = text.layer, let clipped = silkscreenClips[layer]?.object(text.id) {
                addClippedSilkscreen(
                    clipped, layer: layer, to: &build, opacity: 0.82,
                    height: textOverlayHeight(for: layer, board: board, boardThickness: build.boardThickness)
                )
                continue
            }
            let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
            guard !segments.isEmpty else {
                continue
            }
            // The glyph strokes as capsules, one flat sheet per text: glyph
            // strokes are microns thick, so a single face with a double-sided
            // material reads the same as a solid at a fraction of the
            // vertices. Overlaps at the joints share one depth and draw
            // once, so no union is needed. Every text of a layer is one mesh.
            let strokeWidth = max(text.width, text.size * 0.035, 35_000)
            let radius = strokeWidth / 2
            let capsules = segments.compactMap { segment in
                traceCapsulePoints(from: segment.0, to: segment.1, radius: radius, segments: 8)
            }
            let isSilkscreen = text.layer.map { HorizontalBoardLayers.category(for: $0) == .silkscreen } ?? false
            let color = build.materialPalette.color(for: text.layer)
            // Silkscreen text takes the silkscreen's colour, solid; other text
            // keeps its layer's, a little translucent.
            let material = BoardSceneMaterialSpec.overlay(color, opacity: isSilkscreen ? 1 : 0.82, emission: 0.14, roughness: 0.64)
            let height = textOverlayHeight(for: text.layer, board: board, boardThickness: build.boardThickness)
            let center = build.center
            build.meshes.append(
                group: isSilkscreen ? .silkscreen : .text,
                explodeFactor: explodeFactor(for: text.layer, board: board, boardThickness: build.boardThickness),
                role: isSilkscreen ? .silkscreen : .fixed,
                materials: [material],
                drawOrder: isSilkscreen ? .silkscreen : .text,
                name: "texts:\(text.layer ?? -1):\(height)"
            ) { builder in
                appendFlat(capsules.map { [$0] }, center: center, y: height, facingUp: !(text.layer.map(isBottomSideLayer) ?? false), to: &builder)
            }
        }
    }

    private static func appendOverlayPolygon(
        _ polygon: HorizontalPolygon,
        group: BoardSceneGroup,
        role: BoardSceneMaterialRole,
        drawOrder: BoardSceneDrawOrder,
        to build: inout Build,
        opacity: Double,
        yOffset: Double
    ) {
        let contours = bridgedClosedSceneContours(from: polygon.renderVertices(arcPrecision: 32))
        guard !contours.isEmpty else {
            return
        }

        let color = build.materialPalette.color(for: polygon.layer)
        let isPaste = polygon.layer.map { HorizontalBoardLayers.category(for: $0) == .paste } ?? false
        let material = isPaste
            ? BoardSceneMaterialSpec.paste(color)
            : BoardSceneMaterialSpec.overlay(color, opacity: opacity, emission: 0.16, roughness: 0.62)
        let height = overlayHeight(for: polygon.layer, board: build.board, boardThickness: build.boardThickness) + yOffset
        let extrusionDirection: Double = polygon.layer.map { isBottomSideLayer($0) } == true ? -1 : 1
        let center = build.center
        build.meshes.append(
            group: group,
            explodeFactor: explodeFactor(for: polygon.layer, board: build.board, boardThickness: build.boardThickness),
            role: role,
            materials: [material],
            drawOrder: isPaste ? nil : drawOrder,
            name: "polygons:\(polygon.layer ?? -1):\(height)"
        ) { builder in
            if !appendFilledPolygon(contours: contours, center: center, y: height, thickness: 0.012, extrusionDirection: extrusionDirection, to: &builder) {
                appendExtruded(
                    polygonFragments(polygon.renderVertices(arcPrecision: 32)),
                    center: center, thickness: 0.012, centerY: height, faceSlot: 0, wallSlot: 0, to: &builder
                )
            }
        }
    }

    /// The lines of one layer — already unioned into fragments — as one thin
    /// mesh.
    private static func appendOverlayLines(
        fragments: [[[HorizontalPoint]]],
        layer: Int?,
        group: BoardSceneGroup,
        role: BoardSceneMaterialRole,
        drawOrder: BoardSceneDrawOrder,
        to build: inout Build,
        opacity: Double,
        yOffset: Double
    ) {
        guard !fragments.isEmpty else {
            return
        }
        let color = build.materialPalette.color(for: layer)
        let isPaste = layer.map { HorizontalBoardLayers.category(for: $0) == .paste } ?? false
        let material = isPaste
            ? BoardSceneMaterialSpec.paste(color)
            : BoardSceneMaterialSpec.overlay(color, opacity: opacity, emission: 0.12, roughness: 0.66)
        let centerY = overlayHeight(for: layer, board: build.board, boardThickness: build.boardThickness) + yOffset
        let center = build.center
        build.meshes.append(
            group: group,
            explodeFactor: explodeFactor(for: layer, board: build.board, boardThickness: build.boardThickness),
            role: role,
            materials: [material],
            drawOrder: isPaste ? nil : drawOrder,
            name: "lines:\(layer ?? -1):\(centerY)"
        ) { builder in
            appendExtruded(fragments, center: center, thickness: 0.012, centerY: centerY, faceSlot: 0, wallSlot: 0, to: &builder)
        }
    }

    // MARK: Axes

    private static func addBoardOriginAxes(to build: inout Build, width: Double, depth: Double) {
        let y = boardTopHeight + 0.16
        let length = Float(min(max(width, depth) * 0.08, 6))
        let origin = scenePoint(.zero, center: build.center, y: y)
        let xEnd = origin + SIMD3(length, 0, 0)
        let yEnd = origin + SIMD3(0, 0, -length)
        let red = BoardSceneColor(red: 1, green: 0, blue: 0)
        let green = BoardSceneColor(red: 0, green: 1, blue: 0)
        for (end, color, label) in [(xEnd, red, "X"), (yEnd, green, "Y")] {
            let material = BoardSceneMaterialSpec(color: color, emission: color.withAlpha(0.12), opacity: 0.7)
            build.meshes.append(group: .origin, explodeFactor: nil, materials: [material], drawOrder: .outline, name: "origin:\(label)") { builder in
                appendCylinder(from: origin, to: end, radius: 0.018, to: &builder)
            }
            build.labels.append(BoardSceneLabel(text: label, position: end + SIMD3(repeating: 0.16), scale: 0.32, color: color.withAlpha(0.82), bold: true, group: .origin))
        }
    }

    private static func addOrientationAxes(to build: inout Build, width: Double, depth: Double) {
        let origin = SIMD3(Float(-width / 2 + 1.2), Float(boardTopHeight + 0.9), Float(-depth / 2 + 1.2))
        let length: Float = 1.3
        let axes: [(String, SIMD3<Float>, BoardSceneColor)] = [
            ("X", origin + SIMD3(length, 0, 0), BoardSceneColor(red: 1, green: 0, blue: 0)),
            ("Y", origin + SIMD3(0, length, 0), BoardSceneColor(red: 0, green: 1, blue: 0)),
            ("Z", origin + SIMD3(0, 0, length), BoardSceneColor(red: 0, green: 78.0 / 255.0, blue: 208.0 / 255.0))
        ]
        for (label, end, color) in axes {
            let material = BoardSceneMaterialSpec(color: color, emission: color.withAlpha(0.12), opacity: 0.76)
            build.meshes.append(group: .orientationAxes, explodeFactor: nil, materials: [material], drawOrder: .outline, name: "axis:\(label)") { builder in
                appendCylinder(from: origin, to: end, radius: 0.025, to: &builder)
            }
            build.labels.append(BoardSceneLabel(text: label, position: end + SIMD3(repeating: 0.16), scale: 0.32, color: color.withAlpha(0.82), bold: true, group: .orientationAxes))
        }
    }

    // MARK: Lights

    /// A key light from the front right, high, a fill from the back left and
    /// a rim from behind — the three lights SceneKit had, aimed the same way —
    /// and one shining up at the underside, which SceneKit's ambient light lit
    /// and RealityKit has no ambient light for. The key casts no shadow: with
    /// the camera still, RealityKit's directional shadow kept changing from
    /// frame to frame, so the copper, mask and silkscreen flickered between
    /// lit states.
    static func lights(width: Double, depth: Double) -> [BoardSceneLight] {
        func direction(pitch: Double, yaw: Double) -> SIMD3<Float> {
            // SceneKit's euler angles turn by the roll, then the yaw, then
            // the pitch; a light shines down its -z.
            let rotation = simd_float4x4(rotationAbout: SIMD3(1, 0, 0), angle: Float(pitch))
                * simd_float4x4(rotationAbout: SIMD3(0, 1, 0), angle: Float(yaw))
            let shine = rotation * SIMD4<Float>(0, 0, -1, 0)
            return simd_normalize(SIMD3(shine.x, shine.y, shine.z))
        }
        return [
            BoardSceneLight(direction: direction(pitch: -.pi / 3.2, yaw: .pi / 4.5), intensity: 2_600, castsShadow: false),
            BoardSceneLight(direction: direction(pitch: -.pi / 5, yaw: -.pi / 3), intensity: 600, castsShadow: false),
            BoardSceneLight(direction: direction(pitch: -.pi / 4, yaw: .pi), intensity: 850, castsShadow: false),
            BoardSceneLight(direction: simd_normalize(SIMD3(0.7, 1, 0.5)), intensity: 1_000, castsShadow: false),
        ]
    }

    // MARK: Strokes and clipping

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

    static func drillCutoutPaths(for layer: Int?, board: HorizontalBoard) -> [[HorizontalPoint]] {
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

        // A cutout is a solid region to remove, whatever way round it was
        // drawn. Clipper unions them with the nonzero rule, where a clockwise
        // path counts against a counter-clockwise one: a drill overlapping a
        // pour's clockwise thermal-gap hole cancelled it there, and copper
        // came back over the drill instead of leaving it.
        let orientedCutouts = cutouts.map { path in
            HorizontalBoardOutlines.signedArea(path) < 0 ? Array(path.reversed()) : path
        }

        let rawFragments = BoardSceneClipperPathStorage.withPaths(subjects, orientedCutouts) { subjectStorage, cutoutStorage in
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

    /// A polygon's contours as a single fragment (outer first, then the
    /// holes its keyhole bridges hid).
    private static func polygonFragments(_ vertices: [HorizontalPoint]) -> [[[HorizontalPoint]]] {
        let contours = bridgedClosedSceneContours(from: vertices)
        return contours.isEmpty ? [] : [contours]
    }

    /// Stroked polylines unioned into fragments: the way silkscreen lines,
    /// text and copper traces of one layer become one mesh.
    private static func unionedStrokeFragments(_ capsules: [[HorizontalPoint]]) -> [[[HorizontalPoint]]] {
        guard !capsules.isEmpty else {
            return []
        }
        let fragments = clippedSceneFragments(subjects: capsules, cutouts: [])
        return fragments.isEmpty ? capsules.map { [$0] } : fragments
    }

    /// An arc as the segment the stroke builders understand.
    private static func segment(for arc: HorizontalArc) -> HorizontalSegment {
        HorizontalSegment(
            id: arc.id, from: arc.from, to: arc.to, width: arc.width,
            layer: arc.layer, center: arc.center, reverse: arc.reverse, netID: arc.netID
        )
    }

    // MARK: Slab fragments

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
                // The outer ring is counter-clockwise, and the tessellator
                // keeps that winding for every triangle it emits.
                let triangles = HorizontalMetalTessellator.fragmentTriangles(contours, color: black).map { triangle in
                    (triangle.a, triangle.b, triangle.c)
                }
                return Fragment(contours: contours, triangles: triangles)
            }
        }
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
        return tiledFragments(outer: outer, cutouts: Array(contours.dropFirst()) + relevant)
    }

    /// `outer` minus `cutouts` as fragments; cut into tiles once the
    /// cutouts are many, so no earcut sees more than a few holes. One
    /// clipper pass splits the outer along hairline strips on the grid
    /// lines (a 40 nm gap nothing can see), then each piece loses only the
    /// cutouts that touch it: linear in the size of the footprint, where
    /// clipping the whole outer once per tile was quadratic.
    private static func tiledFragments(outer: [HorizontalPoint], cutouts allCutouts: [[HorizontalPoint]]) -> SlabFragments {
        guard !allCutouts.isEmpty else {
            return SlabFragments(fragments: [[outer]])
        }
        if allCutouts.count <= untiledCutoutLimit {
            let fragments = clippedSceneFragments(subjects: [outer], cutouts: allCutouts)
            return SlabFragments(fragments: fragments.isEmpty ? [[outer]] : fragments)
        }

        let bounds = HorizontalRect(points: outer)
        let columns = max(Int((bounds.width / slabTileSize).rounded(.up)), 1)
        let rows = max(Int((bounds.height / slabTileSize).rounded(.up)), 1)
        let seamXs = (1..<columns).map { bounds.minX + bounds.width * Double($0) / Double(columns) }
        let seamYs = (1..<rows).map { bounds.minY + bounds.height * Double($0) / Double(rows) }
        let halfGap = 20.0
        var strips = [[HorizontalPoint]]()
        for x in seamXs {
            strips.append([
                HorizontalPoint(x: x - halfGap, y: bounds.minY - halfGap),
                HorizontalPoint(x: x + halfGap, y: bounds.minY - halfGap),
                HorizontalPoint(x: x + halfGap, y: bounds.maxY + halfGap),
                HorizontalPoint(x: x - halfGap, y: bounds.maxY + halfGap),
            ])
        }
        for y in seamYs {
            strips.append([
                HorizontalPoint(x: bounds.minX - halfGap, y: y - halfGap),
                HorizontalPoint(x: bounds.maxX + halfGap, y: y - halfGap),
                HorizontalPoint(x: bounds.maxX + halfGap, y: y + halfGap),
                HorizontalPoint(x: bounds.minX - halfGap, y: y + halfGap),
            ])
        }
        let pieces = strips.isEmpty ? [[outer]] : clippedSceneFragments(subjects: [outer], cutouts: strips)
        guard !pieces.isEmpty else {
            let fragments = clippedSceneFragments(subjects: [outer], cutouts: allCutouts)
            return SlabFragments(fragments: fragments.isEmpty ? [[outer]] : fragments)
        }

        let cutoutBounds = allCutouts.map { HorizontalRect(points: $0) }
        var fragments = [[[HorizontalPoint]]]()
        for piece in pieces {
            guard let pieceOuter = piece.first else {
                continue
            }
            let pieceBounds = HorizontalRect(points: pieceOuter)
            let relevant = zip(allCutouts, cutoutBounds)
                .filter { $0.1.intersects(pieceBounds) }
                .map(\.0)
            if relevant.isEmpty {
                fragments.append(piece)
            } else {
                fragments.append(contentsOf: clippedSceneFragments(subjects: [pieceOuter], cutouts: Array(piece.dropFirst()) + relevant))
            }
        }
        return SlabFragments(fragments: fragments, seamXs: seamXs, seamYs: seamYs)
    }

    // MARK: Meshes

    /// `template` as one extruded solid: top and bottom faces from its
    /// triangulation, a wall along every contour edge that is not a tile
    /// seam, between `topY - thickness` and `topY`. A face's triangles share
    /// their corners, one vertex per contour point per face, where the
    /// SceneKit meshes had three of their own per triangle.
    private static func appendExtruded(
        _ template: ExtrudedMeshTemplate,
        center: HorizontalPoint,
        thickness: Double,
        topY: Double,
        faceSlot: Int,
        wallSlot: Int,
        to builder: inout BoardSceneMeshBuilder
    ) {
        let top = Float(topY)
        let bottom = Float(topY - thickness)

        func isSeam(_ first: HorizontalPoint, _ second: HorizontalPoint) -> Bool {
            // The strips that split the tiles leave the pieces 20 nm short
            // of the grid line on either side.
            let tolerance = 100.0
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

        let up = SIMD3<Float>(0, 1, 0)
        let down = SIMD3<Float>(0, -1, 0)
        for fragment in template.fragments where !fragment.triangles.isEmpty {
            var topIndices = [HorizontalPoint: UInt32]()
            var bottomIndices = [HorizontalPoint: UInt32]()
            builder.reserveVertices(fragment.contours.reduce(0) { $0 + $1.count } * 6)
            func vertex(_ point: HorizontalPoint, top isTop: Bool) -> UInt32 {
                if isTop {
                    if let index = topIndices[point] { return index }
                    let index = builder.addVertex(planePoint(point, center: center, y: top), normal: up)
                    topIndices[point] = index
                    return index
                }
                if let index = bottomIndices[point] { return index }
                let index = builder.addVertex(planePoint(point, center: center, y: bottom), normal: down)
                bottomIndices[point] = index
                return index
            }
            for (a, b, c) in fragment.triangles {
                builder.addTriangle(vertex(a, top: true), vertex(b, top: true), vertex(c, top: true), slot: faceSlot)
                builder.addTriangle(vertex(c, top: false), vertex(b, top: false), vertex(a, top: false), slot: faceSlot)
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
                    let normal = SIMD3<Float>(Float(dy / length), 0, Float(dx / length))
                    builder.addQuad((
                        planePoint(first, center: center, y: bottom),
                        planePoint(second, center: center, y: bottom),
                        planePoint(second, center: center, y: top),
                        planePoint(first, center: center, y: top)
                    ), normal: normal, slot: wallSlot)
                }
            }
        }
    }

    /// `fragments` as one extruded solid whose mid-plane sits at `centerY`,
    /// faces in the first material and walls in the second.
    private static func appendExtruded(
        _ fragments: [[[HorizontalPoint]]],
        center: HorizontalPoint,
        thickness: Double,
        centerY: Double,
        faceSlot: Int = 0,
        wallSlot: Int = 1,
        to builder: inout BoardSceneMeshBuilder
    ) {
        let template = ExtrudedMeshTemplate(SlabFragments(fragments: fragments))
        guard !template.isEmpty else {
            return
        }
        let depth = max(thickness, 0.004)
        appendExtruded(template, center: center, thickness: depth, topY: centerY + depth / 2, faceSlot: faceSlot, wallSlot: wallSlot, to: &builder)
    }

    /// All of `fragments` as one flat sheet at height `y`: the top faces
    /// only, no thickness, so a translucent material covers the area exactly
    /// once.
    private static func appendFlat(
        _ fragments: [[[HorizontalPoint]]],
        center: HorizontalPoint,
        y: Double,
        facingUp: Bool,
        to builder: inout BoardSceneMeshBuilder
    ) {
        let black = HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 1)
        let normal = SIMD3<Float>(0, facingUp ? 1 : -1, 0)
        let height = Float(y)
        for fragment in fragments {
            let triangles = HorizontalMetalTessellator.triangles(for: fragment, color: black)
            var indices = [HorizontalPoint: UInt32]()
            func vertex(_ point: HorizontalPoint) -> UInt32 {
                if let index = indices[point] { return index }
                let index = builder.addVertex(planePoint(point, center: center, y: height), normal: normal)
                indices[point] = index
                return index
            }
            for triangle in triangles {
                if facingUp {
                    builder.addTriangle(vertex(triangle.a), vertex(triangle.b), vertex(triangle.c))
                } else {
                    builder.addTriangle(vertex(triangle.c), vertex(triangle.b), vertex(triangle.a))
                }
            }
        }
    }

    /// A polygon `thickness` deep with its base at `y`, growing up — or,
    /// with a negative `extrusionDirection`, down — from there. False when
    /// it would not triangulate.
    private static func appendFilledPolygon(
        contours: [[HorizontalPoint]],
        center: HorizontalPoint,
        y: Double,
        thickness: Double,
        extrusionDirection: Double,
        to builder: inout BoardSceneMeshBuilder
    ) -> Bool {
        let triangles = HorizontalMetalTessellator.triangles(
            for: contours,
            color: HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 1)
        )
        guard !triangles.isEmpty, thickness > 0 else {
            return false
        }

        let outwardSign: Float = extrusionDirection < 0 ? -1 : 1
        let baseY = Float(y)
        let outerY = Float(y) + Float(thickness) * outwardSign
        let outerNormal = SIMD3<Float>(0, outwardSign, 0)
        let baseNormal = SIMD3<Float>(0, -outwardSign, 0)
        var outerIndices = [HorizontalPoint: UInt32]()
        var baseIndices = [HorizontalPoint: UInt32]()
        func vertex(_ point: HorizontalPoint, outer: Bool) -> UInt32 {
            if outer {
                if let index = outerIndices[point] { return index }
                let index = builder.addVertex(planePoint(point, center: center, y: outerY), normal: outerNormal)
                outerIndices[point] = index
                return index
            }
            if let index = baseIndices[point] { return index }
            let index = builder.addVertex(planePoint(point, center: center, y: baseY), normal: baseNormal)
            baseIndices[point] = index
            return index
        }
        for triangle in triangles {
            builder.addTriangle(vertex(triangle.a, outer: true), vertex(triangle.b, outer: true), vertex(triangle.c, outer: true))
            builder.addTriangle(vertex(triangle.c, outer: false), vertex(triangle.b, outer: false), vertex(triangle.a, outer: false))
        }

        for contour in contours {
            let contour = cleanedClosedScenePoints(contour)
            guard contour.count >= 3 else {
                continue
            }

            for index in contour.indices {
                let first = contour[index]
                let second = contour[(index + 1) % contour.count]
                let firstScene = planePoint(first, center: center, y: 0)
                let secondScene = planePoint(second, center: center, y: 0)
                let dx = secondScene.x - firstScene.x
                let dz = secondScene.z - firstScene.z
                let length = max((dx * dx + dz * dz).squareRoot(), 0.000001)
                let normal = SIMD3<Float>(dz / length, 0, -dx / length)
                builder.addQuad((
                    planePoint(first, center: center, y: baseY),
                    planePoint(second, center: center, y: baseY),
                    planePoint(second, center: center, y: outerY),
                    planePoint(first, center: center, y: outerY)
                ), normal: normal)
            }
        }
        return true
    }

    /// A thin round bar from `start` to `end`: panel outlines and axes.
    private static func appendCylinder(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, segments: Int = 12, to builder: inout BoardSceneMeshBuilder) {
        let axis = end - start
        let length = simd_length(axis)
        guard length > 0.01 else {
            return
        }
        let direction = axis / length
        let helper: SIMD3<Float> = abs(direction.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(direction, helper))
        let v = simd_cross(direction, u)
        var ring = [(UInt32, UInt32)]()
        for index in 0..<segments {
            let angle = Float(index) / Float(segments) * 2 * .pi
            let normal = u * cos(angle) + v * sin(angle)
            let low = builder.addVertex(start + normal * radius, normal: normal)
            let high = builder.addVertex(end + normal * radius, normal: normal)
            ring.append((low, high))
        }
        for index in 0..<segments {
            let (low, high) = ring[index]
            let (nextLow, nextHigh) = ring[(index + 1) % segments]
            builder.addTriangle(low, nextLow, nextHigh)
            builder.addTriangle(low, nextHigh, high)
        }
    }

    // MARK: Contours

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
        // The triangulator is much happier when that topologically holeless
        // bridge is restored to a real hole; otherwise the coincident bridge
        // edges can collapse.
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

    // MARK: Positions and heights

    /// A board point at height `y`, in the scene.
    static func scenePoint(_ point: HorizontalPoint, center: HorizontalPoint, y: Double) -> SIMD3<Float> {
        SIMD3(
            Float((point.x - center.x) / unitsPerMillimeter),
            Float(y),
            Float(-(point.y - center.y) / unitsPerMillimeter)
        )
    }

    private static func planePoint(_ point: HorizontalPoint, center: HorizontalPoint, y: Float) -> SIMD3<Float> {
        SIMD3(
            Float((point.x - center.x) / unitsPerMillimeter),
            y,
            Float(-(point.y - center.y) / unitsPerMillimeter)
        )
    }

    static func copperHeight(
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
        // The silkscreen is a flat sheet just off the mask's outer face.
        if layer == HorizontalBoardLayers.topSilkscreen {
            return solderMaskOuterSurfaceHeight(
                for: HorizontalBoardLayers.topMask,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: layerSeparation
            ) + layerSurfaceGap
        }
        if layer == HorizontalBoardLayers.bottomSilkscreen {
            return solderMaskOuterSurfaceHeight(
                for: HorizontalBoardLayers.bottomMask,
                board: board,
                boardThickness: boardThickness,
                layerSeparation: layerSeparation
            ) - layerSurfaceGap
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

    private static func padExtrusionDepth(for layer: Int?, board: HorizontalBoard? = nil) -> Double {
        guard let layer else {
            return copperVisualThickness
        }
        if HorizontalBoardLayers.category(for: layer) == .paste {
            return solderPasteThickness
        }
        if HorizontalBoardLayers.category(for: layer) == .solderMask {
            return solderMaskThickness
        }
        return copperThickness(for: layer, board: board)
    }

    /// Returns the (top, bottom) scene-y span of a via given its layer
    /// connectivity. Through-holes default to the full board thickness; blind
    /// and buried vias use the via's `connectedLayers` to span only the copper
    /// layers they actually reach.
    static func viaZSpan(
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

    /// How far artwork stands off its layer's surface, away from the board:
    /// up on the top side, down on the bottom.
    private static func overlayArtworkYOffset(for layer: Int?, fallback: Double) -> Double {
        (isSilkscreenLayer(layer) ? layerSurfaceGap : fallback) * outwardSign(for: layer)
    }

    private static func textOverlayHeight(
        for layer: Int?,
        board: HorizontalBoard? = nil,
        boardThickness: Double,
        layerSeparation: Double = 0
    ) -> Double {
        let offset = (isSilkscreenLayer(layer) ? layerSurfaceGap : 0.045) * outwardSign(for: layer)
        return overlayHeight(for: layer, board: board, boardThickness: boardThickness, layerSeparation: layerSeparation) + offset
    }

    /// Away from the board's core: -1 for a bottom-side layer, else 1.
    private static func outwardSign(for layer: Int?) -> Double {
        layer.map(isBottomSideLayer) == true ? -1 : 1
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
}

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

extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(translation, 1)
    }

    /// A turn by `angle` radians about `axis`, counter-clockwise looking
    /// down the axis.
    init(rotationAbout axis: SIMD3<Float>, angle: Float) {
        self.init(simd_quatf(angle: angle, axis: simd_normalize(axis)))
    }

    /// `point` moved by this transform.
    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let moved = self * SIMD4(point, 1)
        return SIMD3(moved.x, moved.y, moved.z)
    }
}
