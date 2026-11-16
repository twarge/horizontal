import Foundation

/// Changes of place for packages, each its own, made in one pass over the
/// board.
///
/// A package takes along what stands on its pads and holes: the ends of the
/// tracks and net ties there on the pad's net, and the junctions there. Taken
/// one package at a time, every track and junction on the board was read
/// again for each package it moved, and again for each pad of one it turned
/// or mirrored, with a point key written for both ends of every track. On a
/// board of 400 parts of eight pads and 3,200 tracks, a quarter turn of them
/// all took 3 s and lining them up 8 s (Debug); with twice the parts, four
/// times as long. Here the pads and holes of every package that changes
/// place are keyed first, each with how far its package takes it, and the
/// tracks, net ties and junctions are read once.
///
/// What stood on a pad is found on the board as it was before the change, as
/// the move's preview finds it (`BoardMovePlanner`) and as
/// `BoardMovingPoints` finds what a junction or via carries, so an end goes
/// once. Package by package, an end one package had put where the next one's
/// pad still stood went on again with that one.
enum BoardPackageMoves {
    /// What a package does.
    enum Change: Equatable {
        /// Moves by a shift.
        case shift(HorizontalPoint)
        /// Turns about a point by an angle, in the board's angle units.
        case turn(about: HorizontalPoint, by: Int)
        /// Mirrors across the vertical line through a point, onto the other
        /// side of the board.
        case mirror(about: HorizontalPoint)
        /// Goes to the other side of the board where it stands, Horizon's
        /// `flip` (board_package.cpp `update_package`: `placement.mirror =
        /// flip`, with every layer of its geometry flipped top to bottom),
        /// not the mirror tool. Position and angle are kept.
        ///
        /// The geometry is stored transformed (a pool point `p` at `Rot(θ)·
        /// M·p + shift`), so from the unmirrored state to the mirrored one
        /// about the package's origin is a reflection across the package's
        /// own Y axis with a layer flip. A mirror here being a reflection
        /// across the vertical line through the centre, that is: mirror,
        /// with the layer flip, then turn by twice the package's angle about
        /// its origin (checked at 0°, 90°, 45° and 180°). A reload draws the
        /// same geometry from the pool with the saved `flip`.
        case flip
        /// Turns to an angle where it stands, the copper on its pads left
        /// where it is: what the inspector's Angle has always done.
        case angle(Int)

        /// A move, turn or mirror leaves a fixed package where it is. The
        /// inspector's Flipped and Angle change one all the same, as they
        /// always have.
        fileprivate var sparesFixedPackages: Bool {
            switch self {
            case .shift, .turn, .mirror: true
            case .flip, .angle: false
            }
        }

        fileprivate var carriesCopper: Bool {
            if case .angle = self {
                return false
            }
            return true
        }
    }

    /// A point as `HorizontalCanvasModeSupport.pointKey` tells points apart,
    /// without the string.
    struct PointKey: Hashable {
        var x: Int64
        var y: Int64

        init(_ point: HorizontalPoint) {
            x = Int64(point.x.rounded())
            y = Int64(point.y.rounded())
        }
    }

    /// How many times `apply` has read a board's tracks and junctions, for a
    /// test to count that a change of many packages reads them once. Written
    /// on the main thread only, where the canvas and its tests move packages.
    nonisolated(unsafe) static var passes = 0

    /// The packages a selection names one after another, changed together
    /// when something else comes between them or the selection ends. A
    /// selection's objects are changed in the order it names them, and a
    /// package takes what is on its pads as the objects named before it
    /// left the board, so only packages named in a row can share a pass. A
    /// selection made from the scene, Select All or a box, names all its
    /// packages in a row.
    struct Run {
        var geometry: [String: BoardPackageGeometry]?
        private var changes = [(packageID: String, change: Change)]()

        init(geometry: [String: BoardPackageGeometry]? = nil) {
            self.geometry = geometry
        }

        mutating func add(_ packageID: String, _ change: Change) {
            changes.append((packageID, change))
        }

        /// Makes the changes gathered since the last time, if any.
        mutating func finish(on board: inout HorizontalBoard) {
            guard !changes.isEmpty else {
                return
            }
            BoardPackageMoves.apply(changes, to: &board, geometry: geometry)
            changes.removeAll(keepingCapacity: true)
        }
    }

    /// A pad or hole of a package that changes place: where it stood, its
    /// net, and how far its package takes it.
    private struct Anchor {
        var point: HorizontalPoint
        var netID: String?
        var offset: HorizontalPoint
    }

    /// Moves the packages `packageIDs` name by `delta` on `board`.
    static func apply(
        _ packageIDs: Set<String>,
        by delta: HorizontalPoint,
        to board: inout HorizontalBoard,
        geometry: [String: BoardPackageGeometry]? = nil
    ) {
        let wanted = Set(packageIDs.map(HorizontalCanvasModeSupport.normalizedID))
        // In the board's order, which a set has none of.
        let changes = board.packages.lazy
            .filter { wanted.contains(HorizontalCanvasModeSupport.normalizedID($0.id)) }
            .map { (packageID: $0.id, change: Change.shift(delta)) }
        apply(Array(changes), to: &board, geometry: geometry)
    }

    /// Makes each of `changes` to the package it names on `board`, the
    /// package's geometry and what stands on its pads and holes going with
    /// it. A package named twice takes its first change; a fixed one isn't
    /// moved, turned or mirrored, and one the board lacks is passed over.
    /// `geometry` is where each package's geometry sits
    /// (`BoardPackageGeometry.index`, by normalized id), when the caller has
    /// found it; what it lacks is found here.
    static func apply(
        _ changes: [(packageID: String, change: Change)],
        to board: inout HorizontalBoard,
        geometry: [String: BoardPackageGeometry]? = nil
    ) {
        guard !changes.isEmpty else {
            return
        }
        // The first package of each id, as `firstIndex(where:)` finds it.
        var packageIndex = [String: Int](minimumCapacity: board.packages.count)
        for index in board.packages.indices {
            let id = HorizontalCanvasModeSupport.normalizedID(board.packages[index].id)
            if packageIndex[id] == nil {
                packageIndex[id] = index
            }
        }
        var moving = [(index: Int, id: String, change: Change)]()
        var seen = Set<String>()
        for (packageID, change) in changes {
            let id = HorizontalCanvasModeSupport.normalizedID(packageID)
            guard let index = packageIndex[id], seen.insert(id).inserted,
                  !(board.packages[index].fixed && change.sparesFixedPackages) else {
                continue
            }
            moving.append((index, id, change))
        }
        guard !moving.isEmpty else {
            return
        }
        var geometry = geometry ?? [:]
        let unfound = Set(moving.lazy.map(\.id).filter { geometry[$0] == nil })
        if !unfound.isEmpty {
            geometry.merge(BoardPackageGeometry.index(of: board, packageIDs: unfound)) { found, _ in found }
        }

        // A pad by the centre of its outline and a hole by its position, with
        // the net of each: an end follows on a net of the point it is on. In
        // the order the packages were given, so the first to claim a point
        // takes what is on it, as it did package by package.
        var anchors = [Anchor]()
        var anchorsAt = [PointKey: [Int]]()
        for package in moving where package.change.carriesCopper {
            guard let geometry = geometry[package.id] else {
                continue
            }
            let placement = board.packages[package.index]
            func add(_ point: HorizontalPoint, netID: String?) {
                anchorsAt[PointKey(point), default: []].append(anchors.count)
                anchors.append(Anchor(point: point, netID: netID, offset: offset(of: point, in: package.change, placement: placement)))
            }
            for index in geometry.pads {
                add(HorizontalRect(points: board.packagePads[index].vertices).center, netID: board.packagePads[index].netID)
            }
            for index in geometry.holes {
                add(board.packageHoles[index].position, netID: board.packageHoles[index].netID)
            }
        }

        if !anchors.isEmpty {
            passes += 1
            // Each end is asked about once, where it stood: one that follows
            // a pad isn't looked at again where the change put it.
            func offset(at point: HorizontalPoint, netID: String?) -> HorizontalPoint? {
                guard let here = anchorsAt[PointKey(point)],
                      let anchor = here.first(where: { netsMatch(netID, anchors[$0].netID) }) else {
                    return nil
                }
                return anchors[anchor].offset
            }
            func carryEnds(of segments: inout [HorizontalSegment]) {
                for index in segments.indices {
                    let netID = segments[index].netID
                    if let offset = offset(at: segments[index].from, netID: netID) {
                        segments[index].from = segments[index].from + offset
                    }
                    if let offset = offset(at: segments[index].to, netID: netID) {
                        segments[index].to = segments[index].to + offset
                    }
                }
            }
            carryEnds(of: &board.tracks)
            carryEnds(of: &board.netTies)

            // A junction on a pad goes with it whatever its net, and folds
            // into what it meets where it lands, one pad after another.
            var junctionsOn = [Int: [String]]()
            for (id, position) in board.junctions {
                if let anchor = anchorsAt[PointKey(position)]?.first {
                    junctionsOn[anchor, default: []].append(id)
                }
            }
            BoardTrackRouting.carryJunctions(
                junctionsOn.keys.sorted().map { anchor in
                    (junctionsOn[anchor] ?? [], anchors[anchor].point + anchors[anchor].offset, anchors[anchor].netID)
                },
                board: &board
            )
        }

        let innerLayers = max(board.copperLayerCount - 2, 0)
        for package in moving {
            let placement = board.packages[package.index]
            let parts = geometry[package.id] ?? BoardPackageGeometry()
            switch package.change {
            case .shift(let delta):
                board.packages[package.index].position = placement.position + delta
                shift(parts, by: delta, on: &board)
            case .turn(let center, let angle):
                board.packages[package.index].position = HorizontalCanvasModeSupport.rotated(placement.position, around: center, by: angle)
                board.packages[package.index].angle = HorizontalCanvasModeSupport.wrappedAngle(placement.angle + angle)
                turn(parts, about: center, by: angle, on: &board)
            case .mirror(let center):
                board.packages[package.index].position = HorizontalCanvasModeSupport.mirrored(placement.position, around: center)
                board.packages[package.index].angle = HorizontalCanvasModeSupport.wrappedAngle(-placement.angle)
                board.packages[package.index].mirrored.toggle()
                mirror(parts, about: center, innerLayers: innerLayers, on: &board)
            case .flip:
                mirror(parts, about: placement.position, innerLayers: innerLayers, on: &board)
                turn(parts, about: placement.position, by: 2 * placement.angle, on: &board)
                board.packages[package.index].mirrored.toggle()
            case .angle(let angle):
                board.packages[package.index].angle = angle
                turn(parts, about: placement.position, by: angle - HorizontalCanvasModeSupport.wrappedAngle(placement.angle), on: &board)
            }
        }
    }

    /// How far `change` takes a point of a package placed at `placement`.
    private static func offset(of point: HorizontalPoint, in change: Change, placement: HorizontalPlacement) -> HorizontalPoint {
        switch change {
        case .shift(let delta):
            return delta
        case .turn(let center, let angle):
            return HorizontalCanvasModeSupport.rotated(point, around: center, by: angle) - point
        case .mirror(let center):
            return HorizontalCanvasModeSupport.mirrored(point, around: center) - point
        case .flip:
            let mirrored = HorizontalCanvasModeSupport.mirrored(point, around: placement.position)
            return HorizontalCanvasModeSupport.rotated(mirrored, around: placement.position, by: 2 * placement.angle) - point
        case .angle:
            return .zero
        }
    }

    /// Moves one package's geometry, found at `geometry` on `board`, by
    /// `delta`: its pads with their positions, holes, polygons, lines, arcs,
    /// texts and keepouts.
    private static func shift(_ geometry: BoardPackageGeometry, by delta: HorizontalPoint, on board: inout HorizontalBoard) {
        guard delta != .zero else {
            return
        }
        for index in geometry.pads {
            board.packagePads[index] = HorizontalCanvasModeSupport.shifted(board.packagePads[index], by: delta)
        }
        for key in geometry.padPositionKeys {
            if let position = board.packagePadPositions[key] {
                board.packagePadPositions[key] = position + delta
            }
        }
        for index in geometry.holes {
            board.packageHoles[index] = HorizontalCanvasModeSupport.shifted(board.packageHoles[index], by: delta)
        }
        for index in geometry.polygons {
            board.packagePolygons[index] = HorizontalCanvasModeSupport.shifted(board.packagePolygons[index], by: delta)
        }
        for index in geometry.lines {
            board.packageLines[index] = HorizontalCanvasModeSupport.shifted(board.packageLines[index], by: delta)
        }
        for index in geometry.arcs {
            board.packageArcs[index] = HorizontalCanvasModeSupport.shifted(board.packageArcs[index], by: delta)
        }
        for index in geometry.texts {
            board.packageTexts[index] = HorizontalCanvasModeSupport.shifted(board.packageTexts[index], by: delta)
        }
        for index in geometry.keepouts {
            board.keepouts[index].polygon = HorizontalCanvasModeSupport.shifted(board.keepouts[index].polygon, by: delta)
        }
    }

    /// Turns one package's geometry about `center` by `angle`.
    private static func turn(_ geometry: BoardPackageGeometry, about center: HorizontalPoint, by angle: Int, on board: inout HorizontalBoard) {
        guard HorizontalCanvasModeSupport.wrappedAngle(angle) != 0 else {
            return
        }
        for index in geometry.pads {
            board.packagePads[index] = HorizontalCanvasModeSupport.rotated(board.packagePads[index], around: center, by: angle)
        }
        for key in geometry.padPositionKeys {
            if let position = board.packagePadPositions[key] {
                board.packagePadPositions[key] = HorizontalCanvasModeSupport.rotated(position, around: center, by: angle)
            }
        }
        for index in geometry.holes {
            board.packageHoles[index] = HorizontalCanvasModeSupport.rotated(board.packageHoles[index], around: center, by: angle)
        }
        for index in geometry.polygons {
            board.packagePolygons[index] = HorizontalCanvasModeSupport.rotated(board.packagePolygons[index], around: center, by: angle)
        }
        for index in geometry.lines {
            board.packageLines[index] = HorizontalCanvasModeSupport.rotated(board.packageLines[index], around: center, by: angle)
        }
        for index in geometry.arcs {
            board.packageArcs[index] = HorizontalCanvasModeSupport.rotated(board.packageArcs[index], around: center, by: angle)
        }
        for index in geometry.texts {
            board.packageTexts[index] = HorizontalCanvasModeSupport.rotated(board.packageTexts[index], around: center, by: angle)
        }
        for index in geometry.keepouts {
            board.keepouts[index].polygon = HorizontalCanvasModeSupport.rotated(board.keepouts[index].polygon, around: center, by: angle)
        }
    }

    /// Mirrors one package's geometry across the vertical line through
    /// `center`, onto the other side's layers.
    private static func mirror(
        _ geometry: BoardPackageGeometry,
        about center: HorizontalPoint,
        innerLayers: Int,
        on board: inout HorizontalBoard
    ) {
        for index in geometry.pads {
            board.packagePads[index] = BoardMirror.mirrored(board.packagePads[index], around: center, flippingLayers: innerLayers)
        }
        for key in geometry.padPositionKeys {
            if let position = board.packagePadPositions[key] {
                board.packagePadPositions[key] = HorizontalCanvasModeSupport.mirrored(position, around: center)
            }
        }
        for index in geometry.holes {
            board.packageHoles[index] = BoardMirror.mirrored(board.packageHoles[index], around: center)
        }
        for index in geometry.polygons {
            board.packagePolygons[index] = BoardMirror.mirrored(board.packagePolygons[index], around: center, flippingLayers: innerLayers)
        }
        for index in geometry.lines {
            board.packageLines[index] = BoardMirror.mirrored(board.packageLines[index], around: center, flippingLayers: innerLayers)
        }
        for index in geometry.arcs {
            board.packageArcs[index] = BoardMirror.mirrored(board.packageArcs[index], around: center, flippingLayers: innerLayers)
        }
        for index in geometry.texts {
            board.packageTexts[index] = BoardMirror.mirrored(board.packageTexts[index], around: center, flippingLayers: innerLayers)
        }
        for index in geometry.keepouts {
            board.keepouts[index] = BoardMirror.mirrored(board.keepouts[index], around: center, flippingLayers: innerLayers)
        }
    }

    private static func netsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return HorizontalCanvasModeSupport.normalizedID(lhs) == HorizontalCanvasModeSupport.normalizedID(rhs)
    }
}
