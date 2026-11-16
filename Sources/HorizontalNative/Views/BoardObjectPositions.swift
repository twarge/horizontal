import Foundation

/// Where a board's objects sit in its arrays, by id whatever its case: the
/// first of each id, as `firstIndex(where:)` finds it. An array is keyed
/// once, on the first lookup into it, for a change that looks up many. A move
/// or turn searched an array again for each object of the selection, both ids
/// lowercased at every step, and read every junction and via again for each
/// end of each track it moved, so its time grew with the square of what was
/// selected.
///
/// The positions are those on the board given, and hold on a copy of it
/// while its arrays keep their order and count, as a move, turn or mirror
/// leaves them.
struct BoardObjectPositions {
    private let board: HorizontalBoard
    private var positions = [PartialKeyPath<HorizontalBoard>: [String: Int]]()
    private var junctionIDs: [String: String]?
    private var connectionPoints: Set<BoardPackageMoves.PointKey>?

    init(of board: HorizontalBoard) {
        self.board = board
    }

    /// The index in `objects` of the first object `id` names.
    mutating func index<Object: Identifiable>(
        of id: String,
        in objects: KeyPath<HorizontalBoard, [Object]>
    ) -> Int? where Object.ID == String {
        let normalized = HorizontalCanvasModeSupport.normalizedID(id)
        if let known = positions[objects] {
            return known[normalized]
        }
        let all = board[keyPath: objects]
        var found = [String: Int](minimumCapacity: all.count)
        for index in all.indices {
            let key = HorizontalCanvasModeSupport.normalizedID(all[index].id)
            if found[key] == nil {
                found[key] = index
            }
        }
        positions[objects] = found
        return found[normalized]
    }

    /// Changes the object `id` names in one of the arrays of `changed`, a
    /// copy of the board these positions are of, when it has one.
    mutating func change<Object: Identifiable>(
        _ id: String,
        in objects: WritableKeyPath<HorizontalBoard, [Object]>,
        on changed: inout HorizontalBoard,
        _ change: (Object) -> Object
    ) where Object.ID == String {
        guard let index = index(of: id, in: objects), changed[keyPath: objects].indices.contains(index) else {
            return
        }
        changed[keyPath: objects][index] = change(changed[keyPath: objects][index])
    }

    /// The points that place the object `ref` names on the board, as the
    /// canvas takes them for a selection's pivot: a package's position, a
    /// line's ends and an arc's centre with them, a via's, hole's or text's
    /// position, a junction's point; none when the board lacks the object.
    /// Nil for a kind that isn't found by id in one of the board's arrays,
    /// which the canvas works out itself.
    mutating func anchorPoints(of ref: HorizontalSelectableRef) -> [HorizontalPoint]? {
        switch ref.type {
        case .boardPackage:
            return index(of: ref.id, in: \.packages).map { [board.packages[$0].position] } ?? []
        case .track:
            return ends(of: ref.id, in: \.tracks)
        case .boardNetTie:
            return ends(of: ref.id, in: \.netTies)
        case .boardLine:
            return ends(of: ref.id, in: \.lines)
        case .connectionLine:
            return ends(of: ref.id, in: \.connectionLines)
        case .junction:
            return junction(ref.id).map { [$0.point] } ?? []
        case .boardArc:
            guard let index = index(of: ref.id, in: \.arcs) else {
                return []
            }
            return [board.arcs[index].from, board.arcs[index].to, board.arcs[index].center]
        case .via:
            return index(of: ref.id, in: \.vias).map { [board.vias[$0].position] } ?? []
        case .boardHole:
            // The first of the board's holes, the packages' and the vias'.
            for holes in [\HorizontalBoard.holes, \.packageHoles, \.viaHoles] {
                if let index = index(of: ref.id, in: holes) {
                    return [board[keyPath: holes][index].position]
                }
            }
            return []
        case .text:
            for texts in [\HorizontalBoard.texts, \.packageTexts] {
                if let index = index(of: ref.id, in: texts) {
                    return [board[keyPath: texts][index].position]
                }
            }
            return []
        default:
            return nil
        }
    }

    private mutating func ends(of id: String, in segments: KeyPath<HorizontalBoard, [HorizontalSegment]>) -> [HorizontalPoint] {
        guard let index = index(of: id, in: segments) else {
            return []
        }
        let segment = board[keyPath: segments][index]
        return segment.center.map { [segment.from, segment.to, $0] } ?? [segment.from, segment.to]
    }

    /// The junction `id` names, by the id the board has it under, and where
    /// it is.
    mutating func junction(_ id: String) -> (id: String, point: HorizontalPoint)? {
        if let point = board.junctions[id] {
            return (id, point)
        }
        let ids = junctionIDs ?? Dictionary(
            board.junctions.keys.map { (HorizontalCanvasModeSupport.normalizedID($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        junctionIDs = ids
        guard let known = ids[HorizontalCanvasModeSupport.normalizedID(id)], let point = board.junctions[known] else {
            return nil
        }
        return (known, point)
    }

    /// Whether a junction or a via stands at `point`, and so carries the
    /// copper that ends there (`BoardMovingPoints`).
    mutating func hasMovableConnection(at point: HorizontalPoint) -> Bool {
        let points = connectionPoints ?? Set(
            board.junctions.values.map(BoardPackageMoves.PointKey.init) + board.vias.map { BoardPackageMoves.PointKey($0.position) }
        )
        connectionPoints = points
        return points.contains(BoardPackageMoves.PointKey(point))
    }
}
