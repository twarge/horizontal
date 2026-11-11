import Foundation

/// One of the board's Align and Distribute commands (Edit ▸ Align, Edit ▸
/// Distribute). The edges and centres are the objects' bounding boxes, as
/// Horizon's Align and Distribute does with its bounding-box operations, and
/// distributing leaves equal gaps between the boxes, as its equidistant
/// operations do: the first and the last stay, and the rest are spaced
/// between them.
enum BoardAlignOperation: String, CaseIterable, Identifiable {
    case left
    case center
    case right
    case top
    case middle
    case bottom
    case distributeHorizontally = "distribute_horizontally"
    case distributeVertically = "distribute_vertically"

    var id: String { rawValue }

    static let alignments: [BoardAlignOperation] = [.left, .center, .right, .top, .middle, .bottom]
    static let distributions: [BoardAlignOperation] = [.distributeHorizontally, .distributeVertically]

    /// The menu item's title, under Align or Distribute.
    var title: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .top: "Top"
        case .middle: "Middle"
        case .bottom: "Bottom"
        case .distributeHorizontally: "Horizontally"
        case .distributeVertically: "Vertically"
        }
    }

    /// The undo menu's name for it.
    var actionName: String {
        switch self {
        case .left: "Align Left"
        case .center: "Align Center"
        case .right: "Align Right"
        case .top: "Align Top"
        case .middle: "Align Middle"
        case .bottom: "Align Bottom"
        case .distributeHorizontally: "Distribute Horizontally"
        case .distributeVertically: "Distribute Vertically"
        }
    }

    /// How many objects it takes to do anything: two to line up, three to
    /// space out, since the two outermost stay.
    var minimumCount: Int {
        switch self {
        case .distributeHorizontally, .distributeVertically: 3
        default: 2
        }
    }

    /// The operation as it acts on the board when the view is seen from
    /// below (mirrored): the screen's left is the board's right there, so a
    /// Left typed at the screen lines up the board's right edges.
    func onBoard(viewMirrored: Bool) -> BoardAlignOperation {
        guard viewMirrored else {
            return self
        }
        switch self {
        case .left: return .right
        case .right: return .left
        default: return self
        }
    }
}

/// An object to align: its key, its bounding box on the board, and whether
/// it stays where it is (a fixed package).
struct BoardAlignItem<Key: Hashable> {
    var key: Key
    var bounds: HorizontalRect
    var isFixed = false
}

enum BoardAlignment {
    /// Where each item moves by, for those that move: the target edge or
    /// centre is taken from the whole selection, fixed items included, so a
    /// fixed package can be what the rest line up on, but a fixed item is
    /// never moved itself. The offsets are whole nanometres, as the file
    /// stores a point; an item already in place is left out.
    static func offsets<Key: Hashable>(
        _ operation: BoardAlignOperation,
        items: [BoardAlignItem<Key>]
    ) -> [Key: HorizontalPoint] {
        guard items.count >= operation.minimumCount else {
            return [:]
        }
        var targets = [Key: HorizontalPoint]()
        switch operation {
        case .left:
            let edge = items.map(\.bounds.minX).min() ?? 0
            for item in items { targets[item.key] = HorizontalPoint(x: edge - item.bounds.minX, y: 0) }
        case .right:
            let edge = items.map(\.bounds.maxX).max() ?? 0
            for item in items { targets[item.key] = HorizontalPoint(x: edge - item.bounds.maxX, y: 0) }
        case .center:
            let center = union(items).center.x
            for item in items { targets[item.key] = HorizontalPoint(x: center - item.bounds.center.x, y: 0) }
        case .top:
            let edge = items.map(\.bounds.maxY).max() ?? 0
            for item in items { targets[item.key] = HorizontalPoint(x: 0, y: edge - item.bounds.maxY) }
        case .bottom:
            let edge = items.map(\.bounds.minY).min() ?? 0
            for item in items { targets[item.key] = HorizontalPoint(x: 0, y: edge - item.bounds.minY) }
        case .middle:
            let center = union(items).center.y
            for item in items { targets[item.key] = HorizontalPoint(x: 0, y: center - item.bounds.center.y) }
        case .distributeHorizontally:
            targets = distributed(items, horizontally: true)
        case .distributeVertically:
            targets = distributed(items, horizontally: false)
        }
        var offsets = [Key: HorizontalPoint]()
        for item in items where !item.isFixed {
            guard let offset = targets[item.key]?.rounded, offset != .zero else {
                continue
            }
            offsets[item.key] = offset
        }
        return offsets
    }

    /// Equal gaps between the boxes along one axis, in the order of their
    /// centres (ties by their low edge): the span from the first box's low
    /// edge to the last one's high edge, less the boxes' own sizes, shared
    /// out between the gaps. Overlapping boxes give a negative gap, which
    /// still spaces them evenly.
    private static func distributed<Key: Hashable>(
        _ items: [BoardAlignItem<Key>],
        horizontally: Bool
    ) -> [Key: HorizontalPoint] {
        func low(_ rect: HorizontalRect) -> Double { horizontally ? rect.minX : rect.minY }
        func high(_ rect: HorizontalRect) -> Double { horizontally ? rect.maxX : rect.maxY }
        func middle(_ rect: HorizontalRect) -> Double { (low(rect) + high(rect)) / 2 }
        let sorted = items.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element.bounds, rhs.element.bounds)
            if middle(a) != middle(b) { return middle(a) < middle(b) }
            if low(a) != low(b) { return low(a) < low(b) }
            return lhs.offset < rhs.offset
        }.map(\.element)
        guard let first = sorted.first, let last = sorted.last, sorted.count >= 3 else {
            return [:]
        }
        let span = high(last.bounds) - low(first.bounds)
        let sizes = sorted.reduce(0) { $0 + high($1.bounds) - low($1.bounds) }
        let gap = (span - sizes) / Double(sorted.count - 1)
        var result = [Key: HorizontalPoint]()
        var next = low(first.bounds)
        for item in sorted {
            let shift = next - low(item.bounds)
            result[item.key] = horizontally ? HorizontalPoint(x: shift, y: 0) : HorizontalPoint(x: 0, y: shift)
            next += high(item.bounds) - low(item.bounds) + gap
        }
        // The outermost two stay as they were, whatever rounding gave.
        result[first.key] = .zero
        result[last.key] = .zero
        return result
    }

    private static func union<Key: Hashable>(_ items: [BoardAlignItem<Key>]) -> HorizontalRect {
        HorizontalRect(points: items.flatMap { [HorizontalPoint(x: $0.bounds.minX, y: $0.bounds.minY), HorizontalPoint(x: $0.bounds.maxX, y: $0.bounds.maxY)] })
    }

    /// The selected objects Align and Distribute moves, once each, in the
    /// selection's order: packages, vias, board holes, decals and texts of
    /// the board's own (a package's texts go with their package). Tracks,
    /// lines and polygons have no one place to line up and are left where
    /// they are.
    static func alignableRefs(_ refs: [HorizontalSelectableRef], in board: HorizontalBoard) -> [HorizontalSelectableRef] {
        let types: Set<HorizontalObjectType> = [.boardPackage, .via, .boardHole, .boardDecal, .text]
        let candidates = refs.filter { types.contains($0.type) }
        guard !candidates.isEmpty else {
            return []
        }
        func ids(_ values: [String]) -> Set<String> {
            Set(values.map(HorizontalCanvasModeSupport.normalizedID))
        }
        let present: [HorizontalObjectType: Set<String>] = [
            .boardPackage: ids(board.packages.map(\.id)),
            .via: ids(board.vias.map(\.id)),
            .boardHole: ids(board.holes.map(\.id)),
            .boardDecal: ids(board.decals.map(\.id)),
            .text: ids(board.texts.map(\.id)),
        ]
        var seen = Set<HorizontalSelectableRef>()
        return candidates.filter { ref in
            present[ref.type]?.contains(HorizontalCanvasModeSupport.normalizedID(ref.id)) == true && seen.insert(ref).inserted
        }
    }

    /// The selection's objects to align (`alignableRefs`), each with its
    /// bounding box, whose `bounds` (the boxes the canvas hit-tests them
    /// by) give one at all. A fixed package is marked to stay, and a locked via,
    /// and a package a locked track holds.
    static func items(
        for refs: [HorizontalSelectableRef],
        in board: HorizontalBoard,
        bounds: (HorizontalSelectableRef) -> HorizontalRect?
    ) -> [BoardAlignItem<HorizontalSelectableRef>] {
        let fixed = Set(board.packages.filter(\.fixed).map { HorizontalCanvasModeSupport.normalizedID($0.id) })
        let held = BoardCopperLock.held(in: board)
        return alignableRefs(refs, in: board).compactMap { ref in
            guard let box = bounds(ref) else {
                return nil
            }
            // A via the lock holds stays too, and a package with a locked
            // track on a pad (`BoardCopperLock`).
            let isFixed = ref.type == .boardPackage && fixed.contains(HorizontalCanvasModeSupport.normalizedID(ref.id))
                || (ref.type == .via || ref.type == .boardPackage) && held.holds(ref)
            return BoardAlignItem(key: ref, bounds: box, isFixed: isFixed)
        }
    }

    /// The box round a canvas object's selectables, nil when it has none.
    static func bounds(of selectables: [HorizontalSelectable]) -> HorizontalRect? {
        guard !selectables.isEmpty else {
            return nil
        }
        return HorizontalRect(points: selectables.flatMap { selectable -> [HorizontalPoint] in
            let box = selectable.axisAlignedBounds
            return [box.min, box.max]
        })
    }
}
