import Foundation
#if canImport(HorizontalPlaneClipper)
import HorizontalPlaneClipper
#endif

/// The "clip silkscreen to solder mask" mode: silkscreen closer than
/// `clearance` (nanometres) to a solder mask opening on the same side, or
/// to the board's edge and cutouts, is left out, the way a fab house strips
/// silkscreen off pads and off the routed edge.
struct HorizontalSilkscreenClipping: Hashable {
    var clearance: Double

    static let defaultClearanceMM = 0.1
    static let maximumClearanceMM = 1.0
}

/// One silkscreen object after clipping: what is left of it, as fill
/// fragments (each an outer contour followed by its holes). Empty when the
/// object lay entirely within the clearance of an opening.
struct HorizontalClippedSilkscreenObject: Hashable {
    var id: String
    var fragments: [[[HorizontalPoint]]]
    /// The object as it was when clipped (`HorizontalSilkscreenClipper
    /// .sourceSignature`). A caller holding on to a result past later edits
    /// compares it with the object now, so it never draws fragments for a
    /// line or text that has since moved.
    var sourceSignature: Int
    /// For a stroked object (a line, arc or text), what is left of its
    /// strokes' centerlines in each fragment, by fragment index: two-point
    /// pieces. Empty for a polygon, and for a fragment that is only a sliver
    /// off the side of a stroke. The canvas draws these as hairlines at the
    /// width an unclipped stroke is held to, so a clipped label weighs what
    /// an unclipped one does when zoomed out, where the fill alone goes thin.
    var centerlines: [[[HorizontalPoint]]] = []

    /// The centerline pieces through `fragments[index]`.
    func centerlines(inFragment index: Int) -> [[HorizontalPoint]] {
        centerlines.indices.contains(index) ? centerlines[index] : []
    }
}

/// A silkscreen layer's clipping result. Objects that come nowhere near a
/// mask opening are absent: they draw and export exactly as before.
struct HorizontalClippedSilkscreenLayer: Hashable {
    var layer: Int
    /// Keyed by the object's normalised id.
    var clipped: [String: HorizontalClippedSilkscreenObject]

    func object(_ id: String) -> HorizontalClippedSilkscreenObject? {
        clipped[HorizontalCanvasModeSupport.normalizedID(id)]
    }

    /// The clipped object, but only while `source` is still the object that
    /// was clipped: nil once it has been moved or reshaped since.
    func object<Source: Hashable>(_ id: String, matching source: Source) -> HorizontalClippedSilkscreenObject? {
        guard let object = object(id),
              object.sourceSignature == HorizontalSilkscreenClipper.sourceSignature(source) else {
            return nil
        }
        return object
    }
}

enum HorizontalSilkscreenClipper {
    /// A stroke narrower than this (a zero-width text, say) is clipped at
    /// this width so something is left to draw.
    static let minimumStrokeWidth: Double = 20_000

    /// The mask layer that decides what is stripped from `layer`.
    static func maskLayer(forSilkscreen layer: Int) -> Int? {
        switch layer {
        case HorizontalBoardLayers.topSilkscreen: HorizontalBoardLayers.topMask
        case HorizontalBoardLayers.bottomSilkscreen: HorizontalBoardLayers.bottomMask
        default: nil
        }
    }

    /// Both silkscreen layers of `board`, clipped.
    static func clip(board: HorizontalBoard, clipping: HorizontalSilkscreenClipping) -> [Int: HorizontalClippedSilkscreenLayer] {
        var result = [Int: HorizontalClippedSilkscreenLayer]()
        for layer in [HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen] {
            if let clipped = clippedLayer(layer, board: board, clipping: clipping) {
                result[layer] = clipped
            }
        }
        return result
    }

    /// The solder mask openings on `maskLayer`: pad mask shapes, via mask
    /// openings, and mask polygons drawn on the board, in packages or decals.
    static func maskOpenings(on maskLayer: Int, board: HorizontalBoard) -> [[HorizontalPoint]] {
        var openings = [[HorizontalPoint]]()
        for pad in horizonPadOutlineFragments(board.packagePads.filter { $0.layer == maskLayer }) {
            openings.append(contentsOf: pad.paths.filter { $0.count >= 3 })
        }
        for via in board.vias {
            let opening = via.maskOutline(on: maskLayer)
            if opening.count >= 3 {
                openings.append(opening)
            }
        }
        for polygon in board.polygons + board.packagePolygons where polygon.layer == maskLayer {
            let vertices = polygon.renderVertices(arcPrecision: 32)
            if vertices.count >= 3 {
                openings.append(vertices)
            }
        }
        for decal in board.decals {
            for polygon in decal.polygons where polygon.layer == maskLayer {
                let vertices = polygon.renderVertices(arcPrecision: 32)
                if vertices.count >= 3 {
                    openings.append(vertices)
                }
            }
        }
        return openings
    }

    /// `layer` clipped against the openings of its mask layer. Nil for a
    /// layer that is not silkscreen.
    static func clippedLayer(
        _ layer: Int,
        board: HorizontalBoard,
        clipping: HorizontalSilkscreenClipping
    ) -> HorizontalClippedSilkscreenLayer? {
        guard let maskLayer = maskLayer(forSilkscreen: layer) else {
            return nil
        }
        let key = CacheKey(
            boardID: board.uuid,
            layer: layer,
            clearance: clipping.clearance,
            signature: signature(for: layer, maskLayer: maskLayer, board: board)
        )
        if let cached = cache.value(for: key) {
            return cached
        }
        let result = computeClippedLayer(layer, maskLayer: maskLayer, board: board, clearance: clipping.clearance)
        cache.setValue(result, for: key)
        return result
    }

    private static func computeClippedLayer(
        _ layer: Int,
        maskLayer: Int,
        board: HorizontalBoard,
        clearance: Double
    ) -> HorizontalClippedSilkscreenLayer {
        let openings = maskOpenings(on: maskLayer, board: board)
        let edge = boardEdge(of: board)
        guard !openings.isEmpty || !edge.outlinePaths.isEmpty else {
            return HorizontalClippedSilkscreenLayer(layer: layer, clipped: [:])
        }
        let openingBounds = openings.map { HorizontalRect(points: $0).expanded(by: clearance) }
        var clipped = [String: HorizontalClippedSilkscreenObject]()
        for object in silkscreenObjects(on: layer, board: board) {
            let points = object.subjects.flatMap { $0 }
            guard !points.isEmpty else {
                continue
            }
            let bounds = HorizontalRect(points: points)
            let relevant = zip(openings, openingBounds)
                .filter { rectsTouch($0.1, bounds) }
                .map(\.0)
            let nearEdge = !edge.outlinePaths.isEmpty && !edge.isWellInside(bounds.expanded(by: clearance))
            guard !relevant.isEmpty || nearEdge else {
                continue
            }
            let fragments = nearEdge
                ? clip(subjects: object.subjects, cutouts: relevant, outset: clearance, toOutline: edge.outlinePaths, contractedBy: clearance)
                : subtract(cutouts: relevant, outset: clearance, from: object.subjects)
            clipped[HorizontalCanvasModeSupport.normalizedID(object.id)] = HorizontalClippedSilkscreenObject(
                id: object.id,
                fragments: fragments,
                sourceSignature: object.sourceSignature,
                centerlines: object.centerline.isEmpty
                    ? []
                    : fragments.map { pieces(of: object.centerline, inside: $0) }
            )
        }
        return HorizontalClippedSilkscreenLayer(layer: layer, clipped: clipped)
    }

    // MARK: - Board edge

    /// The board's edge as the silkscreen sees it: the outline layer's
    /// polygons (outers and cutouts alike, for an even-odd union) and the
    /// pieces they make, for the quick "nowhere near the edge" test.
    struct BoardEdge {
        var outlinePaths: [[HorizontalPoint]] = []
        var shapes: [HorizontalBoardOutlineShape] = []

        /// True when `rect` lies inside one board piece and touches none of
        /// its cutouts: such an object needs no edge clipping at all.
        func isWellInside(_ rect: HorizontalRect) -> Bool {
            let corners = [
                HorizontalPoint(x: rect.minX, y: rect.minY),
                HorizontalPoint(x: rect.maxX, y: rect.minY),
                HorizontalPoint(x: rect.maxX, y: rect.maxY),
                HorizontalPoint(x: rect.minX, y: rect.maxY),
            ]
            return shapes.contains { shape in
                corners.allSatisfy { HorizontalBoardOutlines.contains($0, in: shape.vertices) }
                    && !shape.cutouts.contains { cutout in
                        let cutoutBounds = HorizontalRect(points: cutout)
                        return cutoutBounds.minX <= rect.maxX && rect.minX <= cutoutBounds.maxX
                            && cutoutBounds.minY <= rect.maxY && rect.minY <= cutoutBounds.maxY
                    }
            }
        }
    }

    static func boardEdge(of board: HorizontalBoard) -> BoardEdge {
        let shapes = HorizontalBoardOutlines.shapes(from: board.polygons)
        guard !shapes.isEmpty else {
            return BoardEdge()
        }
        return BoardEdge(
            outlinePaths: shapes.flatMap { [$0.vertices] + $0.cutouts },
            shapes: shapes
        )
    }

    // MARK: - Silkscreen objects as fill subjects

    private struct SilkscreenObject {
        var id: String
        var subjects: [[HorizontalPoint]]
        var sourceSignature: Int
        /// The strokes' centerline segments, for a line, arc or text; empty
        /// for a polygon.
        var centerline: [(HorizontalPoint, HorizontalPoint)] = []
    }

    /// What a clipped object records of its source: the line, arc, polygon or
    /// text itself, hashed.
    static func sourceSignature<Source: Hashable>(_ source: Source) -> Int {
        var hasher = Hasher()
        hasher.combine(source)
        return hasher.finalize()
    }

    private static func silkscreenObjects(on layer: Int, board: HorizontalBoard) -> [SilkscreenObject] {
        var objects = [SilkscreenObject]()
        func add<Source: Hashable>(
            _ id: String,
            _ subjects: [[HorizontalPoint]],
            centerline: [(HorizontalPoint, HorizontalPoint)] = [],
            source: Source
        ) {
            let valid = subjects.filter { $0.count >= 3 }
            if !valid.isEmpty {
                objects.append(SilkscreenObject(id: id, subjects: valid, sourceSignature: sourceSignature(source), centerline: centerline))
            }
        }
        func addLine(_ line: HorizontalSegment) {
            add(line.id, strokePaths(for: line), centerline: centerline(for: line), source: line)
        }
        func addArc(_ arc: HorizontalArc) {
            let polyline = arc.polyline(precision: 48)
            add(arc.id, strokePaths(polyline: polyline, width: arc.width), centerline: centerline(polyline: polyline), source: arc)
        }
        func addText(_ text: HorizontalText) {
            add(text.id, strokePaths(for: text), centerline: HorizontalOutlineTextRenderer.outlineSegments(for: text), source: text)
        }
        for line in board.lines + board.packageLines where line.layer == layer {
            addLine(line)
        }
        for arc in board.arcs + board.packageArcs where arc.layer == layer {
            addArc(arc)
        }
        for polygon in board.polygons + board.packagePolygons where polygon.layer == layer {
            add(polygon.id, [polygon.renderVertices(arcPrecision: 24)], source: polygon)
        }
        for text in board.texts + board.packageTexts where text.layer == layer {
            addText(text)
        }
        for decal in board.decals {
            for line in decal.lines where line.layer == layer {
                addLine(line)
            }
            for arc in decal.arcs where arc.layer == layer {
                addArc(arc)
            }
            for polygon in decal.polygons where polygon.layer == layer {
                add(polygon.id, [polygon.renderVertices(arcPrecision: 24)], source: polygon)
            }
            for text in decal.texts where text.layer == layer {
                addText(text)
            }
        }
        return objects
    }

    static func strokePaths(for segment: HorizontalSegment) -> [[HorizontalPoint]] {
        if let arc = segment.arc {
            return strokePaths(polyline: arc.polyline(precision: 48), width: segment.width)
        }
        return [capsule(from: segment.from, to: segment.to, width: segment.width)]
    }

    static func strokePaths(for text: HorizontalText) -> [[HorizontalPoint]] {
        HorizontalOutlineTextRenderer.outlineSegments(for: text).map { from, to in
            capsule(from: from, to: to, width: text.width)
        }
    }

    static func strokePaths(polyline: [HorizontalPoint], width: Double) -> [[HorizontalPoint]] {
        zip(polyline, polyline.dropFirst()).map { from, to in
            capsule(from: from, to: to, width: width)
        }
    }

    /// The centerline `strokePaths(for:)` puts its capsules around.
    static func centerline(for segment: HorizontalSegment) -> [(HorizontalPoint, HorizontalPoint)] {
        if let arc = segment.arc {
            return centerline(polyline: arc.polyline(precision: 48))
        }
        return [(segment.from, segment.to)]
    }

    static func centerline(polyline: [HorizontalPoint]) -> [(HorizontalPoint, HorizontalPoint)] {
        Array(zip(polyline, polyline.dropFirst()))
    }

    /// The parts of `segments` that run inside `fragment` (an outer contour
    /// followed by its holes), as two-point pieces. A stroke's centerline
    /// lies inside its own capsule, so what is left of it after clipping is
    /// exactly the part that stays out of every grown opening and inside the
    /// board: where the fill goes on around it.
    static func pieces(
        of segments: [(HorizontalPoint, HorizontalPoint)],
        inside fragment: [[HorizontalPoint]]
    ) -> [[HorizontalPoint]] {
        let contours = fragment.filter { $0.count >= 3 }
        guard !contours.isEmpty else {
            return []
        }
        let bounds = HorizontalRect(points: contours.flatMap { $0 })
        var pieces = [[HorizontalPoint]]()
        for (from, to) in segments {
            let segmentBounds = HorizontalRect(points: [from, to])
            guard rectsTouch(bounds, segmentBounds) else {
                continue
            }
            let dx = to.x - from.x
            let dy = to.y - from.y
            func point(at t: Double) -> HorizontalPoint {
                HorizontalPoint(x: from.x + dx * t, y: from.y + dy * t)
            }
            guard dx != 0 || dy != 0 else {
                // A dot: kept whole or not at all.
                if evenOddContains(contours, from) {
                    pieces.append([from, to])
                }
                continue
            }
            // Where the segment crosses the fragment's contours, as
            // fractions of the way along it.
            var cuts: [Double] = [0, 1]
            for contour in contours {
                var previous = contour[contour.count - 1]
                for current in contour {
                    defer { previous = current }
                    let ex = current.x - previous.x
                    let ey = current.y - previous.y
                    let denominator = dx * ey - dy * ex
                    guard denominator != 0 else {
                        continue
                    }
                    let ox = previous.x - from.x
                    let oy = previous.y - from.y
                    let t = (ox * ey - oy * ex) / denominator
                    let u = (ox * dy - oy * dx) / denominator
                    if t > 0, t < 1, u >= 0, u <= 1 {
                        cuts.append(t)
                    }
                }
            }
            cuts.sort()
            var runStart: Double?
            var runEnd = 0.0
            for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
                if evenOddContains(contours, point(at: (a + b) / 2)) {
                    if runStart == nil {
                        runStart = a
                    }
                    runEnd = b
                } else if let start = runStart {
                    pieces.append([point(at: start), point(at: runEnd)])
                    runStart = nil
                }
            }
            if let start = runStart {
                pieces.append([point(at: start), point(at: runEnd)])
            }
        }
        return pieces
    }

    /// Even-odd inside test over all of a fragment's contours: inside the
    /// outer contour and outside every hole.
    private static func evenOddContains(_ contours: [[HorizontalPoint]], _ point: HorizontalPoint) -> Bool {
        var inside = false
        for contour in contours {
            var previous = contour[contour.count - 1]
            for current in contour {
                if (current.y > point.y) != (previous.y > point.y),
                   point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                    inside.toggle()
                }
                previous = current
            }
        }
        return inside
    }

    /// The area a stroke of `width` covers between two points: a rectangle
    /// with a half-disc on each end.
    static func capsule(from: HorizontalPoint, to: HorizontalPoint, width: Double, segments: Int = 8) -> [HorizontalPoint] {
        let radius = max(width, minimumStrokeWidth) / 2
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        let heading = length > 0 ? atan2(dy, dx) : 0
        var points = [HorizontalPoint]()
        points.reserveCapacity(segments * 2 + 2)
        func cap(around center: HorizontalPoint, startAngle: Double) {
            for step in 0...segments {
                let angle = startAngle + Double(step) / Double(segments) * Double.pi
                points.append(HorizontalPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            }
        }
        cap(around: to, startAngle: heading - Double.pi / 2)
        cap(around: from, startAngle: heading + Double.pi / 2)
        return points
    }

    // MARK: - Clipping

    /// `subjects` (unioned) minus `cutouts` grown by `outset`.
    static func subtract(cutouts: [[HorizontalPoint]], outset: Double, from subjects: [[HorizontalPoint]]) -> [[[HorizontalPoint]]] {
        #if canImport(HorizontalPlaneClipper)
        let subjectStorage = PathStorage(subjects)
        let cutoutStorage = PathStorage(cutouts)
        guard subjectStorage.count > 0 else {
            return []
        }
        let raw = HorizontalClipperBuildPlaneFill(
            subjectStorage.pointer,
            Int32(subjectStorage.count),
            cutoutStorage.pointer,
            Int32(cutoutStorage.count),
            0,
            outset,
            0
        )
        defer {
            HorizontalClipperFreeFragments(raw)
        }
        return fragments(from: raw)
        #else
        return subjects.map { [$0] }
        #endif
    }

    /// `subjects` minus `cutouts` grown by `outset`, kept inside `outline`
    /// (its paths unioned even-odd, so cutouts drawn on the outline layer
    /// are holes) after the outline is drawn in by `contract`: the plane
    /// pour's own "clip to the board" step.
    static func clip(
        subjects: [[HorizontalPoint]],
        cutouts: [[HorizontalPoint]],
        outset: Double,
        toOutline outline: [[HorizontalPoint]],
        contractedBy contract: Double
    ) -> [[[HorizontalPoint]]] {
        #if canImport(HorizontalPlaneClipper)
        let subjectStorage = PathStorage(subjects)
        let cutoutStorage = PathStorage(cutouts)
        let outlineStorage = PathStorage(outline)
        guard subjectStorage.count > 0 else {
            return []
        }
        var cutoutEntries = (0..<cutoutStorage.count).map { index in
            HorizontalClipperCutout(path: cutoutStorage.pointer![index], outset: outset, joinType: 0, arcTolerance: 2_000)
        }
        let raw = cutoutEntries.withUnsafeMutableBufferPointer { cutoutBuffer -> HorizontalClipperFragmentList in
            var params = HorizontalClipperPlaneFillParams()
            params.subjects = subjectStorage.pointer
            params.subjectCount = Int32(subjectStorage.count)
            params.minWidth = 0
            params.joinType = 0
            params.cutouts = UnsafePointer(cutoutBuffer.baseAddress)
            params.cutoutCount = Int32(cutoutBuffer.count)
            params.boardOutline = outlineStorage.pointer
            params.boardOutlineCount = Int32(outlineStorage.count)
            params.hasBoardOutline = outlineStorage.count > 0 ? 1 : 0
            params.boardOutlineContract = max(contract, 0)
            params.thermalPads = nil
            params.thermalPadCount = 0
            params.fillStyle = 0
            return withUnsafePointer(to: &params) { HorizontalClipperBuildPlaneFillEx($0) }
        }
        defer {
            HorizontalClipperFreeFragments(raw)
        }
        return fragments(from: raw)
        #else
        return subjects.map { [$0] }
        #endif
    }

    #if canImport(HorizontalPlaneClipper)
    private static func fragments(from raw: HorizontalClipperFragmentList) -> [[[HorizontalPoint]]] {
        guard let fragmentPointer = raw.fragments, raw.count > 0 else {
            return []
        }
        var fragments = [[[HorizontalPoint]]]()
        for fragmentIndex in 0..<Int(raw.count) {
            let fragment = fragmentPointer[fragmentIndex]
            guard let pathPointer = fragment.paths, fragment.count > 0 else {
                continue
            }
            var paths = [[HorizontalPoint]]()
            for pathIndex in 0..<Int(fragment.count) {
                let path = pathPointer[pathIndex]
                guard let pointPointer = path.points, path.count >= 3 else {
                    continue
                }
                paths.append((0..<Int(path.count)).map { index in
                    HorizontalPoint(x: pointPointer[index].x, y: pointPointer[index].y)
                })
            }
            if !paths.isEmpty {
                fragments.append(paths)
            }
        }
        return fragments
    }
    #endif

    /// A fragment as one closed contour: each hole is joined to the outer
    /// boundary by a zero-width bridge, for outputs that fill a contour and
    /// know nothing of holes (Gerber regions, ODB++ surfaces, PDF fills).
    static func bridgedContour(_ fragment: [[HorizontalPoint]]) -> [HorizontalPoint] {
        guard var outer = fragment.first, outer.count >= 3 else {
            return []
        }
        let outerClockwise = signedArea(outer) < 0
        for hole in fragment.dropFirst() where hole.count >= 3 {
            // Holes trace the opposite way round so a nonzero fill leaves
            // them open too.
            var oriented = hole
            if (signedArea(oriented) < 0) == outerClockwise {
                oriented.reverse()
            }
            var best = (outer: 0, hole: 0, distance: Double.infinity)
            for (outerIndex, outerPoint) in outer.enumerated() {
                for (holeIndex, holePoint) in oriented.enumerated() {
                    let dx = outerPoint.x - holePoint.x
                    let dy = outerPoint.y - holePoint.y
                    let distance = dx * dx + dy * dy
                    if distance < best.distance {
                        best = (outerIndex, holeIndex, distance)
                    }
                }
            }
            let rotatedHole = Array(oriented[best.hole...] + oriented[..<best.hole])
            var bridged = Array(outer[...best.outer])
            bridged.append(contentsOf: rotatedHole)
            bridged.append(rotatedHole[0])
            bridged.append(contentsOf: outer[best.outer...])
            outer = bridged
        }
        return outer
    }

    private static func signedArea(_ points: [HorizontalPoint]) -> Double {
        guard points.count >= 3 else {
            return 0
        }
        var area = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += current.x * next.y - next.x * current.y
        }
        return area / 2
    }

    private static func rectsTouch(_ a: HorizontalRect, _ b: HorizontalRect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }

    // MARK: - Cache

    private struct CacheKey: Hashable {
        var boardID: String
        var layer: Int
        var clearance: Double
        var signature: Int
    }

    private final class Cache: @unchecked Sendable {
        private var entries = [CacheKey: HorizontalClippedSilkscreenLayer]()
        private var order = [CacheKey]()
        private let lock = NSLock()
        private let capacity = 8

        func value(for key: CacheKey) -> HorizontalClippedSilkscreenLayer? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func setValue(_ value: HorizontalClippedSilkscreenLayer, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            if entries[key] == nil {
                order.append(key)
                if order.count > capacity {
                    entries[order.removeFirst()] = nil
                }
            }
            entries[key] = value
        }
    }

    private static let cache = Cache()

    /// Everything the result depends on: the silkscreen objects on the
    /// layer and the openings on its mask layer.
    private static func signature(for layer: Int, maskLayer: Int, board: HorizontalBoard) -> Int {
        var hasher = Hasher()
        for line in board.lines + board.packageLines where line.layer == layer {
            hasher.combine(line)
        }
        for arc in board.arcs + board.packageArcs where arc.layer == layer {
            hasher.combine(arc)
        }
        for polygon in board.polygons + board.packagePolygons
            where polygon.layer == layer || polygon.layer == maskLayer || polygon.layer == HorizontalBoardLayers.outline {
            hasher.combine(polygon)
        }
        for text in board.texts + board.packageTexts where text.layer == layer {
            hasher.combine(text)
        }
        for pad in board.packagePads where pad.layer == maskLayer {
            hasher.combine(pad)
        }
        hasher.combine(board.vias.count)
        for via in board.vias {
            hasher.combine(via.id)
            hasher.combine(via.position)
            hasher.combine(via.maskOutline(on: maskLayer, segments: 4))
        }
        for decal in board.decals {
            hasher.combine(decal)
        }
        return hasher.finalize()
    }
}

#if canImport(HorizontalPlaneClipper)
private final class PathStorage {
    private let pointBuffers: [UnsafeMutablePointer<HorizontalClipperPoint>]
    private let pathBuffer: UnsafeMutablePointer<HorizontalClipperPath>?
    let count: Int

    var pointer: UnsafePointer<HorizontalClipperPath>? {
        UnsafePointer(pathBuffer)
    }

    init(_ paths: [[HorizontalPoint]]) {
        let validPaths = paths.filter { $0.count >= 3 }
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
}
#endif
