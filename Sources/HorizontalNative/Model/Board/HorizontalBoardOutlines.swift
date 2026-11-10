import Foundation

/// One piece of board as the outline layer draws it: an outer polygon and
/// the cutouts drawn inside it (a polygon on the outline layer that lies
/// within another is a hole, not more board).
struct HorizontalBoardOutlineShape {
    var outer: HorizontalPolygon
    /// The outer's rendered vertices.
    var vertices: [HorizontalPoint]
    /// The rendered vertices of each cutout.
    var cutouts: [[HorizontalPoint]]
    var cutoutPolygons: [HorizontalPolygon]

    var bounds: HorizontalRect {
        HorizontalRect(points: vertices)
    }
}

enum HorizontalBoardOutlines {
    /// The board's shapes from `polygons`: every polygon on the outline
    /// layer, nested by containment. Even depths are board, odd depths are
    /// cutouts of the polygon around them; a polygon inside a cutout is
    /// board again (an island).
    static func shapes(from polygons: [HorizontalPolygon], arcPrecision: Int = 32) -> [HorizontalBoardOutlineShape] {
        let candidates = polygons
            .compactMap { polygon -> (polygon: HorizontalPolygon, vertices: [HorizontalPoint], area: Double)? in
                guard polygon.layer == HorizontalBoardLayers.outline else {
                    return nil
                }
                let vertices = polygon.renderVertices(arcPrecision: arcPrecision)
                guard vertices.count >= 3 else {
                    return nil
                }
                return (polygon, vertices, abs(signedArea(vertices)))
            }
            .sorted { $0.area > $1.area }
        guard !candidates.isEmpty else {
            return []
        }

        // A polygon's parent is the smallest larger polygon that contains it.
        var parents = [Int?](repeating: nil, count: candidates.count)
        for index in candidates.indices {
            let sample = candidates[index].vertices[0]
            var best: Int?
            for other in candidates.indices where other != index && candidates[other].area > candidates[index].area {
                guard contains(sample, in: candidates[other].vertices) else {
                    continue
                }
                if let current = best, candidates[current].area <= candidates[other].area {
                    continue
                }
                best = other
            }
            parents[index] = best
        }
        func depth(of index: Int) -> Int {
            var depth = 0
            var cursor = parents[index]
            while let parent = cursor, depth <= candidates.count {
                depth += 1
                cursor = parents[parent]
            }
            return depth
        }

        var shapes = [HorizontalBoardOutlineShape]()
        for index in candidates.indices where depth(of: index).isMultiple(of: 2) {
            let cutoutIndices = candidates.indices.filter { parents[$0] == index }
            shapes.append(HorizontalBoardOutlineShape(
                outer: candidates[index].polygon,
                vertices: candidates[index].vertices,
                cutouts: cutoutIndices.map { candidates[$0].vertices },
                cutoutPolygons: cutoutIndices.map { candidates[$0].polygon }
            ))
        }
        return shapes
    }

    /// Whether `point` lies inside `polygon` (ray casting, odd crossings).
    static func contains(_ point: HorizontalPoint, in polygon: [HorizontalPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y) {
                let crossing = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossing {
                    inside.toggle()
                }
            }
            previous = index
        }
        return inside
    }

    static func signedArea(_ points: [HorizontalPoint]) -> Double {
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
}
