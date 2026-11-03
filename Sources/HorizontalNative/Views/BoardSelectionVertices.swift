import Foundation

/// What a board selection marks on the objects it holds, and what a click on
/// one of those marks picks: the parts of each selected object that select on
/// their own. A click on one picks it ahead of whatever else lies under the
/// cursor, with no menu to ask which was meant.
///
/// Those parts are a polygon's vertices and arc centres, whichever part of it
/// is selected; the junctions a track, net tie, line, connection line or arc
/// ends on, and an arc's centre; and a dimension's two points and its label,
/// which Horizon previews as one group whichever of them is selected. A track
/// end on a pad stands on no junction, so it marks nothing.
enum BoardSelectionVertices {
    /// The parts `selected` marks, each once, in the order of the selection.
    static func refs(of selected: [HorizontalSelectableRef], in board: HorizontalBoard) -> [HorizontalSelectableRef] {
        let types = Set(selected.map(\.type))
        let polygons = types.contains(where: BoardPolygonParts.isPart)
            ? byID(board.polygons + board.planes.compactMap(\.fallbackPolygon), id: \.id)
            : [:]
        let tracks = types.contains(.track) ? byID(board.tracks, id: \.id) : [:]
        let netTies = types.contains(.boardNetTie) ? byID(board.netTies, id: \.id) : [:]
        let lines = types.contains(.boardLine) ? byID(board.lines, id: \.id) : [:]
        let connectionLines = types.contains(.connectionLine) ? byID(board.connectionLines, id: \.id) : [:]
        let arcs = types.contains(.boardArc) ? byID(board.arcs, id: \.id) : [:]
        let dimensions = types.contains(.dimension) ? byID(board.dimensions, id: \.id) : [:]

        let endsOnJunctions = !types.isDisjoint(with: [.track, .boardNetTie, .boardLine, .connectionLine, .boardArc])
        let junctionsByPoint = endsOnJunctions ? board.junctionIDsByPoint() : [:]
        let junctionLayers = endsOnJunctions ? board.junctionLayers() : [:]
        /// The junction an end is on: the one the file names, while it is
        /// still there, else the one copper on `layer` ends on there.
        func junction(named name: String?, at point: HorizontalPoint, layer: Int?) -> HorizontalSelectableRef? {
            if let name, let position = board.junctions[name],
               HorizontalBoard.junctionPointKey(position) == HorizontalBoard.junctionPointKey(point) {
                return HorizontalSelectableRef(id: name, type: .junction)
            }
            return board.junctionIDs(at: point, joining: layer, layers: junctionLayers, byPoint: junctionsByPoint)
                .first
                .map { HorizontalSelectableRef(id: $0, type: .junction) }
        }

        var result = [HorizontalSelectableRef]()
        var seen = Set<HorizontalSelectableRef>()
        func add(_ ref: HorizontalSelectableRef?) {
            if let ref, seen.insert(ref).inserted {
                result.append(ref)
            }
        }
        func addEnds(of segment: HorizontalSegment, named: Bool) {
            add(junction(named: named ? segment.fromJunctionID : nil, at: segment.from, layer: segment.layer))
            add(junction(named: named ? segment.toJunctionID : nil, at: segment.to, layer: segment.layer))
        }

        var done = Set<HorizontalSelectableRef>()
        for ref in selected {
            let id = HorizontalCanvasModeSupport.normalizedID(ref.id)
            // Each object once, whichever of its parts the selection holds.
            guard done.insert(HorizontalSelectableRef(id: id, type: owner(of: ref.type))).inserted else {
                continue
            }
            switch ref.type {
            case .polygonEdge, .polygonVertex, .polygonArcCenter:
                guard let polygon = polygons[id] else {
                    continue
                }
                for (index, vertex) in polygon.polygonVertices.enumerated() {
                    add(HorizontalSelectableRef(id: polygon.id, type: .polygonVertex, vertex: index, layer: polygon.layer))
                    if vertex.type == .arc {
                        add(HorizontalSelectableRef(id: polygon.id, type: .polygonArcCenter, vertex: index, layer: polygon.layer))
                    }
                }
            case .track:
                tracks[id].map { addEnds(of: $0, named: true) }
            case .boardNetTie:
                netTies[id].map { addEnds(of: $0, named: true) }
            case .boardLine:
                lines[id].map { addEnds(of: $0, named: false) }
            case .connectionLine:
                connectionLines[id].map { addEnds(of: $0, named: false) }
            case .boardArc:
                guard let arc = arcs[id] else {
                    continue
                }
                for point in [arc.from, arc.to, arc.center] {
                    add(junction(named: nil, at: point, layer: arc.layer))
                }
            case .dimension:
                guard let dimension = dimensions[id] else {
                    continue
                }
                for part in [BoardDimensionParts.start, BoardDimensionParts.end, BoardDimensionParts.label] {
                    add(BoardDimensionParts.ref(dimension, part))
                }
            default:
                continue
            }
        }
        return result
    }

    /// The mark a click at `point` picks among `selectables`, the marks'
    /// selectables: the nearest point the click is within `expand` of (a
    /// point selectable's hit box), else the smallest box it is inside (a
    /// dimension's label).
    static func pick(
        at point: HorizontalPoint,
        among selectables: [HorizontalSelectable],
        expand: Double
    ) -> HorizontalSelectableRef? {
        var nearest: (ref: HorizontalSelectableRef, distance: Double)?
        var smallestBox: HorizontalSelectable?
        for selectable in selectables where selectable.inside(point, expand: expand) {
            if selectable.isPoint {
                let distance = (selectable.center - point).length
                if nearest.map({ distance < $0.distance }) ?? true {
                    nearest = (selectable.ref, distance)
                }
            } else if smallestBox.map({ selectable.area < $0.area }) ?? true {
                smallestBox = selectable
            }
        }
        return nearest?.ref ?? smallestBox?.ref
    }

    /// The type that stands for the whole object a part of it belongs to.
    private static func owner(of type: HorizontalObjectType) -> HorizontalObjectType {
        BoardPolygonParts.isPart(type) ? .polygonEdge : type
    }

    private static func byID<T>(_ items: [T], id: (T) -> String) -> [String: T] {
        Dictionary(items.map { (HorizontalCanvasModeSupport.normalizedID(id($0)), $0) }, uniquingKeysWith: { first, _ in first })
    }
}
