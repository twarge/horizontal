import Foundation

/// Where one package's geometry sits in a board's arrays: the indices of its
/// pads, holes, polygons, lines, arcs, texts and keepouts, and the keys of its
/// pad positions. Moving, turning or mirroring a package touches only these.
/// Found by scanning every array again for each package, they took 0.4 s of
/// the commit of a Select All nudge on Weevling's 26 packages (Debug); `index`
/// finds them for all the packages a transform moves in one pass. The indices
/// hold while those arrays keep their order and count, as a move, turn or
/// mirror leaves them.
struct BoardPackageGeometry {
    var pads: [Int] = []
    var holes: [Int] = []
    var polygons: [Int] = []
    var lines: [Int] = []
    var arcs: [Int] = []
    var texts: [Int] = []
    var keepouts: [Int] = []
    var padPositionKeys: [String] = []

    /// The geometry of each of `packageIDs` (normalized) on `board`, an empty
    /// one for a package that has none.
    static func index(of board: HorizontalBoard, packageIDs: Set<String>) -> [String: BoardPackageGeometry] {
        var index = Dictionary(uniqueKeysWithValues: packageIDs.map { ($0, BoardPackageGeometry()) })
        guard !packageIDs.isEmpty else {
            return index
        }
        func add(_ ids: some Sequence<String>, to part: WritableKeyPath<BoardPackageGeometry, [Int]>) {
            for (position, id) in ids.enumerated() {
                if let packageID = BoardMovePlanner.packageID(forGeometryID: id), packageIDs.contains(packageID) {
                    index[packageID]?[keyPath: part].append(position)
                }
            }
        }
        add(board.packagePads.lazy.map(\.id), to: \.pads)
        add(board.packageHoles.lazy.map(\.id), to: \.holes)
        add(board.packagePolygons.lazy.map(\.id), to: \.polygons)
        add(board.packageLines.lazy.map(\.id), to: \.lines)
        add(board.packageArcs.lazy.map(\.id), to: \.arcs)
        add(board.packageTexts.lazy.map(\.id), to: \.texts)
        add(board.keepouts.lazy.map(\.id), to: \.keepouts)
        // Pad position keys are "packageID/padID", normalized, and a package's
        // id can hold a slash itself (a block instance's path), so each prefix
        // up to a slash is tried, as a package's own "packageID/" prefix is.
        for key in board.packagePadPositions.keys {
            var rest = key.startIndex
            while let slash = key[rest...].firstIndex(of: "/") {
                let packageID = String(key[..<slash])
                if packageIDs.contains(packageID) {
                    index[packageID]?.padPositionKeys.append(key)
                }
                rest = key.index(after: slash)
            }
        }
        return index
    }

    /// One package's geometry on `board`.
    init(packageID: String, in board: HorizontalBoard) {
        let id = HorizontalCanvasModeSupport.normalizedID(packageID)
        self = Self.index(of: board, packageIDs: [id])[id] ?? BoardPackageGeometry()
    }

    init() {}
}
