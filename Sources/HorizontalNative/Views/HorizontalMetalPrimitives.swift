import SwiftUI
import HorizontalPlaneClipper
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct HorizontalMetalRGBA: Hashable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    init(red: Float, green: Float, blue: Float, alpha: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        #if canImport(AppKit)
        let platformColor = NSColor(color)
        let resolvedColor = platformColor.usingColorSpace(.deviceRGB)
            ?? platformColor.usingColorSpace(.sRGB)
            ?? .black
        self.init(
            red: Float(resolvedColor.redComponent),
            green: Float(resolvedColor.greenComponent),
            blue: Float(resolvedColor.blueComponent),
            alpha: Float(resolvedColor.alphaComponent)
        )
        #elseif canImport(UIKit)
        let platformColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        platformColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Float(red), green: Float(green), blue: Float(blue), alpha: Float(alpha))
        #else
        self.init(red: 0, green: 0, blue: 0, alpha: 0)
        #endif
    }

    var simd: SIMD4<Float> {
        SIMD4(red, green, blue, alpha)
    }
}

struct HorizontalMetalLinePrimitive: Hashable {
    var from: HorizontalPoint
    var to: HorizontalPoint
    var color: HorizontalMetalRGBA
    var width: Double
    var minimumWidth: Float
    var dashLength: Float
    var dashGap: Float
    var normalOffset: Float
    var outlineOnly: Bool
    var compositeGroup: Int
    var compositeOpacity: Float

    init(
        from: HorizontalPoint,
        to: HorizontalPoint,
        color: HorizontalMetalRGBA,
        width: Double = 0,
        minimumWidth: Float = 1,
        dashLength: Float = 0,
        dashGap: Float = 0,
        normalOffset: Float = 0,
        outlineOnly: Bool = false,
        compositeGroup: Int = 0,
        compositeOpacity: Float = 1
    ) {
        self.from = from
        self.to = to
        self.color = color
        self.width = width
        self.minimumWidth = minimumWidth
        self.dashLength = dashLength
        self.dashGap = dashGap
        self.normalOffset = normalOffset
        self.outlineOnly = outlineOnly
        self.compositeGroup = compositeGroup
        self.compositeOpacity = compositeOpacity
    }
}

struct HorizontalMetalScreenLinePrimitive: Hashable {
    var fromX: Float
    var fromY: Float
    var toX: Float
    var toY: Float
    var color: HorizontalMetalRGBA
    var width: Float
    var dashLength: Float
    var dashGap: Float

    init(
        from: CGPoint,
        to: CGPoint,
        color: HorizontalMetalRGBA,
        width: Float = 1,
        dashLength: Float = 0,
        dashGap: Float = 0
    ) {
        self.fromX = Float(from.x)
        self.fromY = Float(from.y)
        self.toX = Float(to.x)
        self.toY = Float(to.y)
        self.color = color
        self.width = width
        self.dashLength = dashLength
        self.dashGap = dashGap
    }
}

struct HorizontalMetalScreenTrianglePrimitive: Hashable {
    var ax: Float
    var ay: Float
    var bx: Float
    var by: Float
    var cx: Float
    var cy: Float
    var color: HorizontalMetalRGBA

    init(a: CGPoint, b: CGPoint, c: CGPoint, color: HorizontalMetalRGBA) {
        self.ax = Float(a.x)
        self.ay = Float(a.y)
        self.bx = Float(b.x)
        self.by = Float(b.y)
        self.cx = Float(c.x)
        self.cy = Float(c.y)
        self.color = color
    }
}

struct HorizontalMetalTrianglePrimitive: Hashable {
    var a: HorizontalPoint
    var b: HorizontalPoint
    var c: HorizontalPoint
    var color: HorizontalMetalRGBA
    var compositeGroup: Int
    var compositeOpacity: Float

    init(
        a: HorizontalPoint,
        b: HorizontalPoint,
        c: HorizontalPoint,
        color: HorizontalMetalRGBA,
        compositeGroup: Int = 0,
        compositeOpacity: Float = 1
    ) {
        self.a = a
        self.b = b
        self.c = c
        self.color = color
        self.compositeGroup = compositeGroup
        self.compositeOpacity = compositeOpacity
    }
}

struct HorizontalMetalHandlePrimitive: Hashable {
    var center: HorizontalPoint
    var outerColor: HorizontalMetalRGBA
    var innerColor: HorizontalMetalRGBA
    var outerRadius: Float
    var innerRadius: Float
    var shape: HorizontalSelectionHandleShape

    init(
        center: HorizontalPoint,
        outerColor: HorizontalMetalRGBA,
        innerColor: HorizontalMetalRGBA,
        shape: HorizontalSelectionHandleShape = .diamond,
        outerRadius: Float? = nil,
        innerRadius: Float? = nil
    ) {
        self.center = center
        self.outerColor = outerColor
        self.innerColor = innerColor
        self.shape = shape
        self.outerRadius = outerRadius ?? Float(shape.outerRadius)
        self.innerRadius = innerRadius ?? Float(shape.innerRadius)
    }
}

struct HorizontalMetalAnchoredRectPrimitive: Hashable {
    var center: HorizontalPoint
    var color: HorizontalMetalRGBA
    var width: Float
    var height: Float
    var compositeGroup: Int
    var compositeOpacity: Float

    init(
        center: HorizontalPoint,
        color: HorizontalMetalRGBA,
        width: Float,
        height: Float,
        compositeGroup: Int = 0,
        compositeOpacity: Float = 1
    ) {
        self.center = center
        self.color = color
        self.width = width
        self.height = height
        self.compositeGroup = compositeGroup
        self.compositeOpacity = compositeOpacity
    }
}

struct HorizontalMetalLineBufferPatch: Hashable {
    var compositeGroup: Int
    var start: Int
    var primitives: [HorizontalMetalLinePrimitive]
}

struct HorizontalMetalTriangleBufferPatch: Hashable {
    var compositeGroup: Int
    var start: Int
    var primitives: [HorizontalMetalTrianglePrimitive]
}

struct HorizontalMetalAnchoredRectBufferPatch: Hashable {
    var compositeGroup: Int
    var start: Int
    var primitives: [HorizontalMetalAnchoredRectPrimitive]
}

struct HorizontalMetalHandleBufferPatch: Hashable {
    var start: Int
    var primitives: [HorizontalMetalHandlePrimitive]
}

struct HorizontalMetalLineTranslationPatch: Hashable {
    var compositeGroup: Int
    var start: Int
    var count: Int
    var delta: HorizontalPoint
}

struct HorizontalMetalLineEndpointPatch: Hashable {
    var compositeGroup: Int
    var start: Int
    var from: HorizontalPoint?
    var to: HorizontalPoint?
}

struct HorizontalMetalTriangleTranslationPatch: Hashable {
    var compositeGroup: Int
    var start: Int
    var count: Int
    var delta: HorizontalPoint
}

struct HorizontalMetalAnchoredRectTranslationPatch: Hashable {
    var compositeGroup: Int
    var start: Int
    var count: Int
    var delta: HorizontalPoint
}

struct HorizontalMetalHandleTranslationPatch: Hashable {
    var start: Int
    var count: Int
    var delta: HorizontalPoint
}

struct HorizontalMetalBufferPatches: Hashable {
    static let empty = HorizontalMetalBufferPatches()

    var linePatches: [HorizontalMetalLineBufferPatch] = []
    var trianglePatches: [HorizontalMetalTriangleBufferPatch] = []
    var anchoredRectPatches: [HorizontalMetalAnchoredRectBufferPatch] = []
    var handlePatches: [HorizontalMetalHandleBufferPatch] = []
    var lineTranslationPatches: [HorizontalMetalLineTranslationPatch] = []
    var lineEndpointPatches: [HorizontalMetalLineEndpointPatch] = []
    var triangleTranslationPatches: [HorizontalMetalTriangleTranslationPatch] = []
    var anchoredRectTranslationPatches: [HorizontalMetalAnchoredRectTranslationPatch] = []
    var handleTranslationPatches: [HorizontalMetalHandleTranslationPatch] = []

    var isEmpty: Bool {
        linePatches.isEmpty
            && trianglePatches.isEmpty
            && anchoredRectPatches.isEmpty
            && handlePatches.isEmpty
            && lineTranslationPatches.isEmpty
            && lineEndpointPatches.isEmpty
            && triangleTranslationPatches.isEmpty
            && anchoredRectTranslationPatches.isEmpty
            && handleTranslationPatches.isEmpty
    }
}

enum HorizontalMetalTessellator {
    static func triangles(for vertices: [HorizontalPoint], color: HorizontalMetalRGBA) -> [HorizontalMetalTrianglePrimitive] {
        triangulateSimple(vertices, color: color, allowsFanFallback: true)
    }

    static func triangles(for paths: [[HorizontalPoint]], color: HorizontalMetalRGBA) -> [HorizontalMetalTrianglePrimitive] {
        let contours = paths.map(cleaned).filter { $0.count >= 3 }
        guard !contours.isEmpty else {
            return []
        }
        guard contours.count > 1 else {
            return triangles(for: contours[0], color: color)
        }

        let areas = contours.map(signedArea)
        let absoluteAreas = areas.map { abs($0) }
        var parents = Array<Int?>(repeating: nil, count: contours.count)

        for contourIndex in contours.indices {
            guard let sample = contours[contourIndex].first else {
                continue
            }

            var bestParent: Int?
            var bestArea = Double.greatestFiniteMagnitude
            for candidateIndex in contours.indices where candidateIndex != contourIndex {
                guard absoluteAreas[candidateIndex] > absoluteAreas[contourIndex],
                      absoluteAreas[candidateIndex] < bestArea,
                      point(sample, isInsidePolygon: contours[candidateIndex]) else {
                    continue
                }
                bestParent = candidateIndex
                bestArea = absoluteAreas[candidateIndex]
            }
            parents[contourIndex] = bestParent
        }

        var depthCache = Array<Int?>(repeating: nil, count: contours.count)
        func depth(of index: Int) -> Int {
            if let cached = depthCache[index] {
                return cached
            }
            let value: Int
            if let parent = parents[index] {
                value = depth(of: parent) + 1
            } else {
                value = 0
            }
            depthCache[index] = value
            return value
        }

        var result = [HorizontalMetalTrianglePrimitive]()
        for outerIndex in contours.indices where depth(of: outerIndex).isMultiple(of: 2) {
            var outer = contours[outerIndex]
            if signedArea(outer) < 0 {
                outer.reverse()
            }

            let holes = contours.indices
                .filter { parents[$0] == outerIndex && !depth(of: $0).isMultiple(of: 2) }
                .map { holeIndex -> [HorizontalPoint] in
                    var hole = contours[holeIndex]
                    if signedArea(hole) > 0 {
                        hole.reverse()
                    }
                    return hole
                }

            var triangles: [HorizontalMetalTrianglePrimitive]
            if holes.isEmpty {
                triangles = triangulateSimple(outer, color: color, allowsFanFallback: false)
            } else {
                triangles = triangulateWithPoly2Tri(outer: outer, holes: holes, color: color)
                if triangles.isEmpty {
                    triangles = triangulate(outer: outer, holes: holes, color: color)
                }
            }

            guard !triangles.isEmpty else {
                return []
            }
            result.append(contentsOf: triangles)
        }

        return result
    }

    private static func triangulateSimple(
        _ sourceVertices: [HorizontalPoint],
        color: HorizontalMetalRGBA,
        allowsFanFallback: Bool
    ) -> [HorizontalMetalTrianglePrimitive] {
        let vertices = cleaned(sourceVertices)
        guard vertices.count >= 3 else {
            return []
        }
        guard vertices.count > 3 else {
            return [HorizontalMetalTrianglePrimitive(a: vertices[0], b: vertices[1], c: vertices[2], color: color)]
        }

        if isConvex(vertices) {
            let fanVertices = signedArea(vertices) < 0 ? Array(vertices.reversed()) : vertices
            return fanTriangles(for: fanVertices, color: color)
        }

        var indices = Array(vertices.indices)
        if signedArea(vertices) < 0 {
            indices.reverse()
        }

        var result = [HorizontalMetalTrianglePrimitive]()
        var guardCount = 0
        while indices.count > 3, guardCount < vertices.count * vertices.count {
            guardCount += 1
            var clipped = false

            for localIndex in indices.indices {
                let previousIndex = indices[localIndex == indices.startIndex ? indices.index(before: indices.endIndex) : indices.index(before: localIndex)]
                let currentIndex = indices[localIndex]
                let nextIndex = indices[localIndex == indices.index(before: indices.endIndex) ? indices.startIndex : indices.index(after: localIndex)]
                let previous = vertices[previousIndex]
                let current = vertices[currentIndex]
                let next = vertices[nextIndex]

                guard cross(previous, current, next) > 0 else {
                    continue
                }

                var containsPoint = false
                for candidateIndex in indices where candidateIndex != previousIndex && candidateIndex != currentIndex && candidateIndex != nextIndex {
                    if pointsEqual(vertices[candidateIndex], previous)
                        || pointsEqual(vertices[candidateIndex], current)
                        || pointsEqual(vertices[candidateIndex], next) {
                        continue
                    }
                    if point(vertices[candidateIndex], isInsideTriangle: (previous, current, next)) {
                        containsPoint = true
                        break
                    }
                }
                guard !containsPoint else {
                    continue
                }

                result.append(HorizontalMetalTrianglePrimitive(a: previous, b: current, c: next, color: color))
                indices.remove(at: localIndex)
                clipped = true
                break
            }

            if !clipped {
                return allowsFanFallback ? fanTriangles(for: vertices, color: color) : []
            }
        }

        if indices.count == 3 {
            result.append(HorizontalMetalTrianglePrimitive(a: vertices[indices[0]], b: vertices[indices[1]], c: vertices[indices[2]], color: color))
        }
        return result
    }

    private static func triangulate(
        outer sourceOuter: [HorizontalPoint],
        holes sourceHoles: [[HorizontalPoint]],
        color: HorizontalMetalRGBA
    ) -> [HorizontalMetalTrianglePrimitive] {
        var polygon = sourceOuter
        for hole in sourceHoles.sorted(by: { rightmostPoint(in: $0).x > rightmostPoint(in: $1).x }) {
            guard let bridged = bridge(hole: hole, into: polygon) else {
                return []
            }
            polygon = bridged
        }
        return triangulateSimple(polygon, color: color, allowsFanFallback: false)
    }

    private static func triangulateWithPoly2Tri(
        outer: [HorizontalPoint],
        holes: [[HorizontalPoint]],
        color: HorizontalMetalRGBA
    ) -> [HorizontalMetalTrianglePrimitive] {
        let storage = HorizontalMetalPathStorage([outer] + holes)
        guard storage.count > 0 else {
            return []
        }

        let rawTriangles = HorizontalClipperTriangulatePlaneFragment(storage.pointer, Int32(storage.count))
        defer {
            HorizontalClipperFreeTriangles(rawTriangles)
        }

        guard let rawPoints = rawTriangles.points, rawTriangles.count >= 3 else {
            return []
        }

        let pointCount = Int(rawTriangles.count)
        let trianglePointCount = pointCount - (pointCount % 3)
        guard trianglePointCount >= 3 else {
            return []
        }

        var result = [HorizontalMetalTrianglePrimitive]()
        result.reserveCapacity(trianglePointCount / 3)
        var index = 0
        while index + 2 < trianglePointCount {
            result.append(HorizontalMetalTrianglePrimitive(
                a: HorizontalPoint(x: rawPoints[index].x, y: rawPoints[index].y),
                b: HorizontalPoint(x: rawPoints[index + 1].x, y: rawPoints[index + 1].y),
                c: HorizontalPoint(x: rawPoints[index + 2].x, y: rawPoints[index + 2].y),
                color: color
            ))
            index += 3
        }
        return result
    }

    private static func bridge(hole: [HorizontalPoint], into polygon: [HorizontalPoint]) -> [HorizontalPoint]? {
        guard polygon.count >= 3,
              hole.count >= 3,
              let holeIndex = hole.indices.max(by: { lhs, rhs in
                  let left = hole[lhs]
                  let right = hole[rhs]
                  if abs(left.x - right.x) > 0.000001 {
                      return left.x < right.x
                  }
                  return left.y < right.y
              }) else {
            return nil
        }

        let holePoint = hole[holeIndex]
        let candidates = polygon.indices
            .filter { isBridgeVisible(from: holePoint, to: polygon[$0], polygon: polygon, hole: hole) }
            .sorted { lhs, rhs in
                distanceSquared(holePoint, polygon[lhs]) < distanceSquared(holePoint, polygon[rhs])
            }

        let polygonIndex = candidates.first ?? polygon.indices.min {
            distanceSquared(holePoint, polygon[$0]) < distanceSquared(holePoint, polygon[$1])
        }
        guard let polygonIndex else {
            return nil
        }

        let reorderedHole = Array(hole[holeIndex...]) + Array(hole[..<holeIndex])
        let prefix = Array(polygon[...polygonIndex])
        let suffix: [HorizontalPoint]
        if polygonIndex == polygon.index(before: polygon.endIndex) {
            suffix = []
        } else {
            suffix = Array(polygon[polygon.index(after: polygonIndex)...])
        }

        return prefix + reorderedHole + [reorderedHole[0], polygon[polygonIndex]] + suffix
    }

    static func circle(center: HorizontalPoint, radius: Double, color: HorizontalMetalRGBA, segments: Int = 48) -> [HorizontalMetalTrianglePrimitive] {
        guard radius > 0 else {
            return []
        }
        let count = max(segments, 12)
        let vertices = (0..<count).map { index in
            let angle = Double(index) / Double(count) * Double.pi * 2
            return HorizontalPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        return triangles(for: vertices, color: color)
    }

    private static func cleaned(_ vertices: [HorizontalPoint]) -> [HorizontalPoint] {
        var result = [HorizontalPoint]()
        for vertex in vertices {
            if let last = result.last,
               abs(last.x - vertex.x) < 0.000001,
               abs(last.y - vertex.y) < 0.000001 {
                continue
            }
            result.append(vertex)
        }
        if let first = result.first,
           let last = result.last,
           result.count > 1,
           abs(first.x - last.x) < 0.000001,
           abs(first.y - last.y) < 0.000001 {
            result.removeLast()
        }
        return result
    }

    private static func fanTriangles(for vertices: [HorizontalPoint], color: HorizontalMetalRGBA) -> [HorizontalMetalTrianglePrimitive] {
        guard vertices.count >= 3 else {
            return []
        }
        return (1..<(vertices.count - 1)).map { index in
            HorizontalMetalTrianglePrimitive(a: vertices[0], b: vertices[index], c: vertices[index + 1], color: color)
        }
    }

    private static func isConvex(_ vertices: [HorizontalPoint]) -> Bool {
        guard vertices.count >= 3 else {
            return false
        }

        let epsilon = 0.000001
        var sign = 0
        for index in vertices.indices {
            let nextIndex = index == vertices.index(before: vertices.endIndex)
                ? vertices.startIndex
                : vertices.index(after: index)
            let afterNextIndex = nextIndex == vertices.index(before: vertices.endIndex)
                ? vertices.startIndex
                : vertices.index(after: nextIndex)
            let crossProduct = cross(vertices[index], vertices[nextIndex], vertices[afterNextIndex])
            if abs(crossProduct) <= epsilon {
                continue
            }
            let currentSign = crossProduct > 0 ? 1 : -1
            if sign == 0 {
                sign = currentSign
            } else if sign != currentSign {
                return false
            }
        }
        return sign != 0
    }

    private static func signedArea(_ vertices: [HorizontalPoint]) -> Double {
        zip(vertices, Array(vertices.dropFirst()) + [vertices[0]]).reduce(0) { total, pair in
            total + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        } * 0.5
    }

    private static func cross(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func point(_ point: HorizontalPoint, isInsideTriangle triangle: (HorizontalPoint, HorizontalPoint, HorizontalPoint)) -> Bool {
        let epsilon = 0.000001
        let c1 = cross(triangle.0, triangle.1, point)
        let c2 = cross(triangle.1, triangle.2, point)
        let c3 = cross(triangle.2, triangle.0, point)
        return c1 >= -epsilon && c2 >= -epsilon && c3 >= -epsilon
    }

    private static func point(_ point: HorizontalPoint, isInsidePolygon vertices: [HorizontalPoint]) -> Bool {
        guard vertices.count >= 3 else {
            return false
        }

        var inside = false
        for pair in zip(vertices, Array(vertices.dropFirst()) + [vertices[0]]) {
            let first = pair.0
            let second = pair.1
            let crossesRay = (first.y > point.y) != (second.y > point.y)
            if crossesRay {
                let intersectionX = (second.x - first.x) * (point.y - first.y) / (second.y - first.y) + first.x
                if point.x < intersectionX {
                    inside.toggle()
                }
            }
        }
        return inside
    }

    private static func isBridgeVisible(
        from start: HorizontalPoint,
        to end: HorizontalPoint,
        polygon: [HorizontalPoint],
        hole: [HorizontalPoint]
    ) -> Bool {
        guard !pointsEqual(start, end) else {
            return false
        }

        func intersectsBlockedEdge(in contour: [HorizontalPoint]) -> Bool {
            for pair in zip(contour, Array(contour.dropFirst()) + [contour[0]]) {
                let first = pair.0
                let second = pair.1
                if pointsEqual(first, start) || pointsEqual(second, start) || pointsEqual(first, end) || pointsEqual(second, end) {
                    continue
                }
                if segmentsIntersect(start, end, first, second) {
                    return true
                }
            }
            return false
        }

        return !intersectsBlockedEdge(in: polygon) && !intersectsBlockedEdge(in: hole)
    }

    private static func segmentsIntersect(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint, _ d: HorizontalPoint) -> Bool {
        let epsilon = 0.000001
        let d1 = cross(a, b, c)
        let d2 = cross(a, b, d)
        let d3 = cross(c, d, a)
        let d4 = cross(c, d, b)

        if ((d1 > epsilon && d2 < -epsilon) || (d1 < -epsilon && d2 > epsilon))
            && ((d3 > epsilon && d4 < -epsilon) || (d3 < -epsilon && d4 > epsilon)) {
            return true
        }

        if abs(d1) <= epsilon && point(c, isOnSegmentFrom: a, to: b) {
            return true
        }
        if abs(d2) <= epsilon && point(d, isOnSegmentFrom: a, to: b) {
            return true
        }
        if abs(d3) <= epsilon && point(a, isOnSegmentFrom: c, to: d) {
            return true
        }
        if abs(d4) <= epsilon && point(b, isOnSegmentFrom: c, to: d) {
            return true
        }
        return false
    }

    private static func point(_ point: HorizontalPoint, isOnSegmentFrom start: HorizontalPoint, to end: HorizontalPoint) -> Bool {
        let epsilon = 0.000001
        return point.x >= min(start.x, end.x) - epsilon
            && point.x <= max(start.x, end.x) + epsilon
            && point.y >= min(start.y, end.y) - epsilon
            && point.y <= max(start.y, end.y) + epsilon
    }

    private static func rightmostPoint(in vertices: [HorizontalPoint]) -> HorizontalPoint {
        vertices.max { lhs, rhs in
            if abs(lhs.x - rhs.x) > 0.000001 {
                return lhs.x < rhs.x
            }
            return lhs.y < rhs.y
        } ?? .zero
    }

    private static func distanceSquared(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func pointsEqual(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.000001 && abs(lhs.y - rhs.y) < 0.000001
    }
}

private final class HorizontalMetalPathStorage {
    private let pointBuffers: [UnsafeMutablePointer<HorizontalClipperPoint>]
    private let pathBuffer: UnsafeMutablePointer<HorizontalClipperPath>?
    let count: Int

    var pointer: UnsafePointer<HorizontalClipperPath>? {
        UnsafePointer(pathBuffer)
    }

    init(_ paths: [[HorizontalPoint]]) {
        var buffers = [UnsafeMutablePointer<HorizontalClipperPoint>]()
        let validPaths = paths.filter { $0.count >= 3 }
        count = validPaths.count
        pathBuffer = count > 0 ? UnsafeMutablePointer<HorizontalClipperPath>.allocate(capacity: count) : nil

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
