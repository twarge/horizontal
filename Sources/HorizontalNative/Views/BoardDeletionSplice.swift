import Foundation

/// What a delete did to the board, when taking copper off is all it did:
/// tracks, net ties and vias with their drills went, the junctions the
/// connectivity pass let go with them, and some of the copper left may have
/// changed net. The scene and selectables built for the board before the
/// delete can then drop what went and draw again only the copper whose net
/// changed, rather than the whole board being built again: on Caleb (195
/// packages, 6514 pads, 26 planes) that build took 2.6 s of a single track's
/// delete, and the selectables another 1.1 s (Debug, under load), to draw
/// what the scene already held less one track.
///
/// A track cut off from its pads goes net-less and draws orange, and its
/// label names its net, so copper that changed net is drawn again. Nothing
/// else about the copper left may have changed, and every other kind of
/// object has to be there in the same number: a delete that took anything
/// else (a package, a polygon, a plane) has no splice, and the scene is built
/// as before.
struct BoardDeletionSplice {
    struct Owner: Hashable {
        var type: HorizontalObjectType
        var id: String
    }

    /// The objects that went, by type and lowercased id.
    let removed: Set<Owner>
    /// The copper left whose net changed, by type and lowercased id.
    let redrawn: Set<Owner>
    /// That copper as the delete left it, for drawing again.
    let redrawnTracks: [HorizontalSegment]
    let redrawnNetTies: [HorizontalSegment]
    let redrawnVias: [HorizontalMarker]
    let redrawnViaHoles: [HorizontalHole]
    private let removedTypes: Set<HorizontalObjectType>
    private let replacedTypes: Set<HorizontalObjectType>

    /// The splice from `previous` to `resolved`, the board the delete's
    /// connectivity pass made; nil when the delete did more than remove copper.
    init?(from previous: HorizontalBoard, to resolved: HorizontalBoard) {
        guard Self.otherCounts(of: previous) == Self.otherCounts(of: resolved),
              let tracks = Self.changes(from: previous.tracks, to: resolved.tracks, id: \.id),
              let netTies = Self.changes(from: previous.netTies, to: resolved.netTies, id: \.id),
              let vias = Self.changes(from: previous.vias, to: resolved.vias, id: \.id),
              let viaHoles = Self.changes(from: previous.viaHoles, to: resolved.viaHoles, id: \.id) else {
            return nil
        }
        // A via's drill draws as the via: the drills that went have to be
        // those of vias that went, and one that changed net is drawn again
        // with its via.
        func viaID(ofHole id: String) -> String {
            (HorizontalBoard.viaID(ofViaHole: id) ?? id).lowercased()
        }
        guard viaHoles.removed.allSatisfy({ vias.removed.contains(viaID(ofHole: $0)) }) else {
            return nil
        }
        let redrawnViaIDs = Set(vias.redrawn.map { $0.id.lowercased() } + viaHoles.redrawn.map { viaID(ofHole: $0.id) })
        // Junctions are not drawn, and stand for a point alone: one that
        // stays has to stay where it was.
        for (key, point) in resolved.junctions where previous.junctions[key] != point {
            return nil
        }
        var removed = Set(tracks.removed.map { Owner(type: .track, id: $0) })
        removed.formUnion(netTies.removed.map { Owner(type: .boardNetTie, id: $0) })
        removed.formUnion(vias.removed.map { Owner(type: .via, id: $0) })
        removed.formUnion(previous.junctions.keys.filter { resolved.junctions[$0] == nil }.map { Owner(type: .junction, id: $0.lowercased()) })
        guard !removed.isEmpty else {
            return nil
        }
        var redrawn = Set(tracks.redrawn.map { Owner(type: .track, id: $0.id.lowercased()) })
        redrawn.formUnion(netTies.redrawn.map { Owner(type: .boardNetTie, id: $0.id.lowercased()) })
        redrawn.formUnion(redrawnViaIDs.map { Owner(type: .via, id: $0) })
        self.removed = removed
        self.redrawn = redrawn
        redrawnTracks = tracks.redrawn
        redrawnNetTies = netTies.redrawn
        redrawnVias = resolved.vias.filter { redrawnViaIDs.contains($0.id.lowercased()) }
        redrawnViaHoles = resolved.viaHoles.filter { redrawnViaIDs.contains(viaID(ofHole: $0.id)) }
        removedTypes = Set(removed.map(\.type))
        replacedTypes = Set(removed.union(redrawn).map(\.type))
    }

    /// Whether `owner` is one of the objects that went; a ref's layer and
    /// vertex don't matter, all of an object's primitives go.
    func removes(_ owner: HorizontalSelectableRef?) -> Bool {
        guard let owner, removedTypes.contains(owner.type) else {
            return false
        }
        return removed.contains(Owner(type: owner.type, id: owner.id.lowercased()))
    }

    /// Whether what `owner` drew leaves the scene: it went, or it is drawn
    /// again.
    func replaces(_ owner: HorizontalSelectableRef?) -> Bool {
        guard let owner, replacedTypes.contains(owner.type) else {
            return false
        }
        let key = Owner(type: owner.type, id: owner.id.lowercased())
        return removed.contains(key) || redrawn.contains(key)
    }

    /// The board to build what is drawn again from: the copper that changed
    /// net, the airwires and the connection lines, and what drawing those
    /// reads (the pad positions a track's label looks for, the nets, the
    /// rules), without the rest of the board.
    func redrawnBoard(of resolved: HorizontalBoard) -> HorizontalBoard {
        var board = resolved
        board.tracks = redrawnTracks
        board.netTies = redrawnNetTies
        board.vias = redrawnVias
        board.viaHoles = redrawnViaHoles
        board.packages = []
        board.packagePads = []
        board.packageHoles = []
        board.packagePolygons = []
        board.packageLines = []
        board.packageArcs = []
        board.packageTexts = []
        board.keepouts = []
        board.junctions = [:]
        board.junctionNetIDs = [:]
        board.lines = []
        board.arcs = []
        board.polygons = []
        board.planes = []
        board.dimensions = []
        board.decals = []
        board.holes = []
        board.texts = []
        board.boardPanels = []
        board.pads = []
        board.padstackShapes = []
        return board
    }

    /// What `resolved` no longer has of `previous`, by lowercased id, and what
    /// it has with another net; nil when anything else differs, or is new.
    private static func changes<Element: Equatable & BoardNetCarrying>(
        from previous: [Element],
        to resolved: [Element],
        id: KeyPath<Element, String>
    ) -> (removed: Set<String>, redrawn: [Element])? {
        var before = Dictionary(previous.map { ($0[keyPath: id].lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var redrawn = [Element]()
        for element in resolved {
            guard var earlier = before.removeValue(forKey: element[keyPath: id].lowercased()) else {
                return nil
            }
            if earlier == element {
                continue
            }
            earlier.netID = element.netID
            guard earlier == element else {
                return nil
            }
            redrawn.append(element)
        }
        return (Set(before.keys), redrawn)
    }

    /// The number of everything a copper delete leaves alone.
    private static func otherCounts(of board: HorizontalBoard) -> [Int] {
        [
            board.polygons.count, board.keepouts.count, board.planes.count, board.decals.count,
            board.dimensions.count, board.lines.count, board.arcs.count, board.connectionLines.count,
            board.holes.count, board.packageHoles.count, board.packages.count, board.packagePads.count,
            board.packagePolygons.count, board.packageLines.count, board.packageArcs.count, board.pads.count,
            board.padstackShapes.count, board.packageTexts.count, board.texts.count, board.boardPanels.count,
        ]
    }
}

/// Copper whose net the connectivity pass sets.
protocol BoardNetCarrying {
    var netID: String? { get set }
}

extension HorizontalSegment: BoardNetCarrying {}
extension HorizontalMarker: BoardNetCarrying {}
extension HorizontalHole: BoardNetCarrying {}

extension BoardMetalElementBatch {
    /// This batch without the primitives whose owner `drops`. A text's
    /// strokes share their owner, so its run goes or stays whole.
    func removingOwners(where drops: (HorizontalSelectableRef?) -> Bool) -> BoardMetalElementBatch {
        guard lineOwners.contains(where: drops)
                || triangleOwners.contains(where: drops)
                || anchoredRectOwners.contains(where: drops) else {
            return self
        }
        var result = BoardMetalElementBatch()
        result.lines.reserveCapacity(lines.count)
        result.lineOwners.reserveCapacity(lines.count)
        result.lineLabelSizes.reserveCapacity(lines.count)
        var runIndex = 0
        for index in lines.indices {
            let owner = index < lineOwners.count ? lineOwners[index] : nil
            while runIndex < textRuns.count, textRuns[runIndex].lineStart < index {
                runIndex += 1
            }
            if drops(owner) {
                continue
            }
            if runIndex < textRuns.count, textRuns[runIndex].lineStart == index {
                var run = textRuns[runIndex]
                run.lineStart = result.lines.count
                result.textRuns.append(run)
            }
            result.lines.append(lines[index])
            result.lineOwners.append(owner)
            result.lineLabelSizes.append(index < lineLabelSizes.count ? lineLabelSizes[index] : 0)
        }
        for index in triangles.indices {
            let owner = index < triangleOwners.count ? triangleOwners[index] : nil
            if !drops(owner) {
                result.appendTriangle(triangles[index], owner: owner)
            }
        }
        for index in anchoredRects.indices {
            let owner = index < anchoredRectOwners.count ? anchoredRectOwners[index] : nil
            if !drops(owner) {
                result.appendAnchoredRect(anchoredRects[index], owner: owner)
            }
        }
        return result
    }
}

extension BoardMetalElementBuckets {
    /// This scene less what `splice` takes out, plus `addition`, a build of
    /// `splice.redrawnBoard`: its copper is added, and the `replacing`
    /// batches are taken from it alone, as `merged` takes them.
    func spliced(
        _ splice: BoardDeletionSplice,
        adding addition: BoardMetalElementBuckets,
        replacing replaced: [ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>]
    ) -> BoardMetalElementBuckets {
        let result = BoardMetalElementBuckets()
        for keyPath in Self.batchKeyPaths {
            if replaced.contains(keyPath) {
                result[keyPath: keyPath] = addition[keyPath: keyPath]
            } else {
                var batch = self[keyPath: keyPath].removingOwners(where: splice.replaces)
                batch.append(contentsOf: addition[keyPath: keyPath])
                result[keyPath: keyPath] = batch
            }
        }
        result.airwires = replaced.contains(\.connectionLines) ? addition.airwires : airwires
        return result
    }
}
