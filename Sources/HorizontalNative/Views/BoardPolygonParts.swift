import Foundation

/// The points of board polygons a move, turn or mirror changes, as Horizon's
/// move tool expands the selection (tool_move's expand_selection): an edge is
/// the two vertices it runs between, a vertex is itself, and an arc's centre
/// changes only when it is selected itself, so moving an arc edge alone
/// reshapes the arc, as it does in Horizon. Each point changes once however
/// many of the selected refs name it: a polygon with every edge, vertex and
/// arc centre selected moves as one piece.
enum BoardPolygonParts {
    struct Parts: Equatable {
        var vertices = Set<Int>()
        var arcCenters = Set<Int>()
    }

    static func isPart(_ type: HorizontalObjectType) -> Bool {
        type == .polygonEdge || type == .polygonVertex || type == .polygonArcCenter
    }

    /// The points of `polygon` that `ref` names.
    static func parts(of ref: HorizontalSelectableRef, in polygon: HorizontalPolygon) -> Parts {
        guard polygon.polygonVertices.indices.contains(ref.vertex) else {
            return Parts()
        }
        switch ref.type {
        case .polygonEdge:
            return Parts(vertices: [ref.vertex, polygon.nextVertexIndex(after: ref.vertex)])
        case .polygonVertex:
            return Parts(vertices: [ref.vertex])
        case .polygonArcCenter:
            return Parts(arcCenters: [ref.vertex])
        default:
            return Parts()
        }
    }

    /// The ids, normalized, of the polygons `refs` reshape: those with a
    /// point that stays where it is. A shift of a polygon's resident spans
    /// draws only a polygon that moves whole.
    static func reshapedPolygonIDs(by refs: [HorizontalSelectableRef], in polygons: [HorizontalPolygon]) -> Set<String> {
        var selected = [String: Parts]()
        for ref in refs where isPart(ref.type) {
            let id = HorizontalCanvasModeSupport.normalizedID(ref.id)
            guard let polygon = polygons.first(where: { HorizontalCanvasModeSupport.normalizedID($0.id) == id }) else {
                continue
            }
            let named = parts(of: ref, in: polygon)
            selected[id, default: Parts()].vertices.formUnion(named.vertices)
            selected[id, default: Parts()].arcCenters.formUnion(named.arcCenters)
        }
        var reshaped = Set<String>()
        for (id, parts) in selected {
            guard let polygon = polygons.first(where: { HorizontalCanvasModeSupport.normalizedID($0.id) == id }) else {
                continue
            }
            let vertices = polygon.polygonVertices
            let arcs = vertices.indices.filter { vertices[$0].type == .arc }
            if parts.vertices.count < vertices.count || !parts.arcCenters.isSuperset(of: arcs) {
                reshaped.insert(id)
            }
        }
        return reshaped
    }

    /// Changes the points of `polygons` that `ref` names by `point`, leaving
    /// those an earlier ref of the same change has changed (`done`, which
    /// this fills). A mirror also turns an arc round where it mirrors the
    /// arc's centre, as Horizon's does.
    static func change(
        _ polygons: inout [HorizontalPolygon],
        ref: HorizontalSelectableRef,
        done: inout Set<String>,
        mirrorsArcs: Bool = false,
        point: (HorizontalPoint) -> HorizontalPoint
    ) {
        let id = HorizontalCanvasModeSupport.normalizedID(ref.id)
        guard let index = polygons.firstIndex(where: { HorizontalCanvasModeSupport.normalizedID($0.id) == id }) else {
            return
        }
        let named = parts(of: ref, in: polygons[index])
        for vertex in named.vertices.sorted() where done.insert("\(id)/vertex/\(vertex)").inserted {
            polygons[index].polygonVertices[vertex].position = point(polygons[index].polygonVertices[vertex].position)
        }
        for vertex in named.arcCenters.sorted() where done.insert("\(id)/arc-center/\(vertex)").inserted {
            polygons[index].polygonVertices[vertex].arcCenter = point(polygons[index].polygonVertices[vertex].arcCenter)
            if mirrorsArcs {
                polygons[index].polygonVertices[vertex].arcReverse.toggle()
            }
        }
    }

    /// What a double-click on `ref` selects: the whole polygon it is an edge,
    /// vertex or arc centre of, as Horizon's double-click on one does (its
    /// Select Polygon action). Nil for a ref that is no part of `polygon`.
    static func doubleClickSelection(of ref: HorizontalSelectableRef, in polygon: HorizontalPolygon?) -> [HorizontalSelectableRef]? {
        guard isPart(ref.type),
              let polygon,
              HorizontalCanvasModeSupport.normalizedID(polygon.id) == HorizontalCanvasModeSupport.normalizedID(ref.id) else {
            return nil
        }
        return wholeSelection(of: polygon)
    }

    /// The click action a double-click's whole polygon is selected with. The
    /// pair's first click has already toggled the part, so a toggle adds the
    /// polygon, as Horizon's Select Polygon adds to the selection, rather
    /// than taking that part back out.
    static func doubleClickAction(for action: HorizontalSelectionClickAction) -> HorizontalSelectionClickAction {
        action == .toggle ? .add : action
    }

    /// Every edge and arc centre of `polygon`, the selection that stands for
    /// the polygon itself, as a paste or a conversion leaves it selected:
    /// moved, it moves whole.
    static func wholeSelection(of polygon: HorizontalPolygon) -> [HorizontalSelectableRef] {
        polygon.polygonVertices.indices.flatMap { index -> [HorizontalSelectableRef] in
            let edge = HorizontalSelectableRef(id: polygon.id, type: .polygonEdge, vertex: index, layer: polygon.layer)
            guard polygon.polygonVertices[index].type == .arc else {
                return [edge]
            }
            return [edge, HorizontalSelectableRef(id: polygon.id, type: .polygonArcCenter, vertex: index, layer: polygon.layer)]
        }
    }
}
