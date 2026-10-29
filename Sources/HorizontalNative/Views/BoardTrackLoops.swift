import Foundation

/// One end of a stretch of route on copper that was on the board before the
/// route: the point, and the copper layer the route has there.
struct BoardTrackLoopEnd: Equatable {
    var point: HorizontalPoint
    var layer: Int
}

/// What one click of the route tool did: what it laid, and what it took off
/// because the route replaces it.
struct BoardTrackLoopStepResult: Equatable {
    var laid: BoardTrackRouteStepResult
    /// Where the route next left copper that was there before it: the click's
    /// end when it reached some, else where the stretch began. Nil while the
    /// route has met none.
    var loopStart: BoardTrackLoopEnd?
    /// The route's tracks so far, this click's included.
    var routeTrackIDs: Set<String>
    /// Tracks and vias taken off because the route now joins what they
    /// joined (`BoardTrackLoops.redundantCopper`).
    var removedTrackIDs: [String]
    var removedViaIDs: [String]
    /// Tracks cut in two at a junction because the route left or reached the
    /// middle of one, by their old ids.
    var splitTrackIDs: [String]
    /// The click closed a loop: it reached copper already joined to where the
    /// stretch began, which ends the route as reaching a pad does.
    var closesLoop: Bool
}

/// Loop removal for the route tool: a route that leaves its net's copper and
/// comes back to it replaces the stretch of copper between the two points,
/// which is taken off when the click lays the route, and hidden from the
/// board while the cursor rests where a click would do it.
///
/// What is replaced is only ever a plain chain: tracks one after another
/// through points where exactly two of them meet, with nothing else there —
/// no pad, no third track, no via but one passing the chain to another layer
/// and joining nothing else. A chain with a branch off it still connects that
/// branch, so it stays, as does anything the route itself laid.
///
/// A route that leaves or reaches the middle of a track cuts it there first,
/// at a junction, so the route joins it, and only the part it replaces goes.
///
/// A click that closes a loop, replacing copper or not, ends the route, as a
/// click on a pad does, and drops no via there.
enum BoardTrackLoops {
    /// One click: `BoardTrackRouting.lay`, after cutting a track whose middle
    /// the route leaves from or reaches, and then, when `removesLoops`, the
    /// copper the route makes redundant between `loopStart` and `target`
    /// taken off. `routeTrackIDs` are the tracks the route laid before. A
    /// click that closes a loop drops no via, since it ends the route.
    static func lay(
        _ specs: [BoardTrackSegmentSpec],
        to target: HorizontalPoint,
        endsOnPad: Bool,
        via: HorizontalBoardViaTemplate?,
        from head: BoardTrackRouteHead,
        loopStart: BoardTrackLoopEnd?,
        routeTrackIDs: Set<String>,
        removesLoops: Bool,
        on board: inout HorizontalBoard
    ) -> BoardTrackLoopStepResult {
        var head = head
        var splitTrackIDs = [String]()
        var reachesCopper = false
        if !specs.isEmpty {
            if !head.anchorOnPad,
               let split = split(at: head.anchor, layer: head.layer, sparing: routeTrackIDs, on: &board) {
                head.anchorJunctionID = split.junctionID
                splitTrackIDs.append(split.trackID)
            }
            if !endsOnPad,
               let split = split(at: target, layer: head.layer, sparing: routeTrackIDs, on: &board) {
                splitTrackIDs.append(split.trackID)
            }
            // Asked before the legs go down, so that only what was there counts.
            reachesCopper = endsOnPad || touchesCopper(target, layer: head.layer, sparing: routeTrackIDs, in: board)
        }
        let closesLoop = reachesCopper && loopStart.map {
            joined($0, BoardTrackLoopEnd(point: target, layer: head.layer), sparing: routeTrackIDs, in: board)
        } == true

        let laid = BoardTrackRouting.lay(
            specs, to: target, endsOnPad: endsOnPad, via: closesLoop ? nil : via, from: head, on: &board)
        let routeIDs = routeTrackIDs.union(laid.trackIDs)

        var removedTrackIDs = [String]()
        var removedViaIDs = [String]()
        if removesLoops, laid.segments > 0, reachesCopper, let loopStart {
            let redundant = redundantCopper(
                from: loopStart,
                to: BoardTrackLoopEnd(point: target, layer: head.layer),
                sparing: routeIDs,
                in: board
            )
            remove(tracks: redundant.trackIDs, vias: redundant.viaIDs, from: &board)
            removedTrackIDs = redundant.trackIDs
            removedViaIDs = redundant.viaIDs
        }

        let nextStart = laid.segments > 0 && reachesCopper
            ? BoardTrackLoopEnd(point: target, layer: laid.head.layer)
            : loopStart
        return BoardTrackLoopStepResult(
            laid: laid,
            loopStart: nextStart,
            routeTrackIDs: routeIDs,
            removedTrackIDs: removedTrackIDs,
            removedViaIDs: removedViaIDs,
            splitTrackIDs: splitTrackIDs,
            closesLoop: closesLoop
        )
    }

    /// Where a route started at `anchor` begins on copper: there, when the
    /// anchor is a pad or touches a track, via or hole, or lies on the middle
    /// of a track on `layer`; else nil.
    static func start(
        at anchor: HorizontalPoint,
        layer: Int,
        onPad: Bool,
        in board: HorizontalBoard
    ) -> BoardTrackLoopEnd? {
        let end = BoardTrackLoopEnd(point: anchor, layer: layer)
        if onPad || touchesCopper(anchor, layer: layer, sparing: [], in: board) {
            return end
        }
        return splittableTrackIndex(at: anchor, layer: layer, sparing: [], in: board) == nil ? nil : end
    }

    /// Whether a click at `point` on `layer` reaches copper that is not the
    /// route's own: a pad, a via or a hole there, a track ending there on
    /// that layer, or the middle of one, which the click would cut.
    static func reachesCopper(
        _ point: HorizontalPoint,
        layer: Int,
        sparing routeTrackIDs: Set<String>,
        in board: HorizontalBoard
    ) -> Bool {
        touchesCopper(point, layer: layer, sparing: routeTrackIDs, in: board)
            || splittableTrackIndex(at: point, layer: layer, sparing: routeTrackIDs, in: board) != nil
    }

    // MARK: - Cutting a track

    /// Cuts the straight track on `layer` whose middle passes through `point`
    /// into two at a junction there, so a route from or to the point joins
    /// it. Both halves are new tracks, since the writer names an existing
    /// track's ends only as it read them. Returns the junction and the old
    /// track's id, or nil when no such track can be cut.
    @discardableResult
    static func split(
        at point: HorizontalPoint,
        layer: Int,
        sparing routeTrackIDs: Set<String>,
        on board: inout HorizontalBoard
    ) -> (junctionID: String, trackID: String)? {
        guard let index = splittableTrackIndex(at: point, layer: layer, sparing: routeTrackIDs, in: board) else {
            return nil
        }
        let track = board.tracks[index]
        let junctionID = BoardTrackRouting.mergeJunctions(at: point, preferredID: nil, netID: track.netID, board: &board)
        var first = track
        first.id = UUID().uuidString.lowercased()
        first.to = point
        var second = track
        second.id = UUID().uuidString.lowercased()
        second.from = point
        board.tracks.replaceSubrange(index...index, with: [first, second])
        return (junctionID, track.id)
    }

    /// The track `split` would cut at `point`: straight, on `layer`, not the
    /// route's, not a panel's copy, with the point on its middle rather than
    /// an end, and with ends the writer can name (a junction or a pad), as
    /// it must for the halves.
    private static func splittableTrackIndex(
        at point: HorizontalPoint,
        layer: Int,
        sparing routeTrackIDs: Set<String>,
        in board: HorizontalBoard
    ) -> Int? {
        let key = Key(point)
        return board.tracks.firstIndex { track in
            track.center == nil
                && layerMatches(track.layer, layer)
                && !routeTrackIDs.contains(track.id)
                && !track.id.contains("/")
                && Key(track.from) != key
                && Key(track.to) != key
                && BoardTrackRouting.pointLiesOnSegment(point, track)
                && namesEnd(track.from, in: board)
                && namesEnd(track.to, in: board)
        }
    }

    private static func namesEnd(_ point: HorizontalPoint, in board: HorizontalBoard) -> Bool {
        let key = Key(point)
        return board.junctions.values.contains { Key($0) == key }
            || board.packagePadPositions.values.contains { Key($0) == key }
    }

    // MARK: - Finding what a route replaces

    /// The copper a route between `start` and `end` makes redundant: every
    /// plain chain of tracks that is not the route's (`routeTrackIDs`) and
    /// runs from one to the other, with the vias inside it. A chain is plain
    /// when each point inside it is where exactly two connected tracks meet
    /// and nothing else is: no pad, hole or net tie, and no via unless the via
    /// passes the chain from one of its layers to another, ends no other
    /// track and stands in no plane's fill.
    static func redundantCopper(
        from start: BoardTrackLoopEnd,
        to end: BoardTrackLoopEnd,
        sparing routeTrackIDs: Set<String>,
        in board: HorizontalBoard
    ) -> (trackIDs: [String], viaIDs: [String]) {
        let startKey = Key(start.point)
        let endKey = Key(end.point)
        guard startKey != endKey else {
            return ([], [])
        }
        var ends = [Key: [Int]]()
        for (index, track) in board.tracks.enumerated() {
            let from = Key(track.from), to = Key(track.to)
            guard from != to else { continue }
            ends[from, default: []].append(index)
            ends[to, default: []].append(index)
        }
        var viasAt = [Key: [Int]]()
        for (index, via) in board.vias.enumerated() {
            viasAt[Key(via.position), default: []].append(index)
        }
        var fixed = Set(board.packagePadPositions.values.map(Key.init))
        fixed.formUnion(board.packageHoles.map { Key($0.position) })
        for tie in board.netTies {
            fixed.insert(Key(tie.from))
            fixed.insert(Key(tie.to))
        }
        let startLayers = layers(at: start, in: board)
        let endLayers = layers(at: end, in: board)

        var trackIDs = [String]()
        var viaIDs = [String]()
        var taken = Set<Int>()
        for first in ends[startKey] ?? [] {
            let track = board.tracks[first]
            guard !routeTrackIDs.contains(track.id),
                  !taken.contains(first),
                  layersContain(startLayers, track.layer) else {
                continue
            }
            var chain = [first]
            var chainVias = [Int]()
            var current = first
            var at = Key(track.from) == startKey ? Key(track.to) : Key(track.from)
            var layer = track.layer ?? start.layer
            var found = false
            while true {
                if at == endKey {
                    found = layersContain(endLayers, layer)
                    break
                }
                guard at != startKey, !fixed.contains(at) else {
                    break
                }
                let here = ends[at] ?? []
                let next: Int
                if let vias = viasAt[at] {
                    guard vias.count == 1, passes(board.vias[vias[0]], in: board) else {
                        break
                    }
                    let span = viaLayers(board.vias[vias[0]], in: board)
                    let joined = here.filter { layersContain(span, board.tracks[$0].layer) }
                    guard joined.count == 2, let other = joined.first(where: { $0 != current }) else {
                        break
                    }
                    chainVias.append(vias[0])
                    next = other
                } else {
                    let joined = here.filter { layerMatches(board.tracks[$0].layer, layer) }
                    guard joined.count == 2, let other = joined.first(where: { $0 != current }) else {
                        break
                    }
                    next = other
                }
                let nextTrack = board.tracks[next]
                guard !routeTrackIDs.contains(nextTrack.id), !chain.contains(next) else {
                    break
                }
                chain.append(next)
                current = next
                at = Key(nextTrack.from) == at ? Key(nextTrack.to) : Key(nextTrack.from)
                layer = nextTrack.layer ?? layer
            }
            guard found else { continue }
            taken.formUnion(chain)
            trackIDs.append(contentsOf: chain.map { board.tracks[$0].id })
            viaIDs.append(contentsOf: chainVias.map { board.vias[$0].id })
        }
        return (trackIDs, viaIDs)
    }

    /// Whether copper other than the route's (`routeTrackIDs`) joins `start`
    /// to `end`: tracks end to end on a layer, and vias, pads and holes from
    /// layer to layer. Plane fills are not followed.
    static func joined(
        _ start: BoardTrackLoopEnd,
        _ end: BoardTrackLoopEnd,
        sparing routeTrackIDs: Set<String>,
        in board: HorizontalBoard
    ) -> Bool {
        let startKey = Key(start.point), endKey = Key(end.point)
        if startKey == endKey {
            return true
        }
        let allLayers = BoardTrackRouting.throughViaLayers(copperLayerCount: board.copperLayerCount)
        var groups = Groups()
        func joinAll(_ key: Key, _ layers: Set<Int>?) {
            let nodes = (layers.map(Array.init) ?? allLayers).map { Node(key: key, layer: $0) }
            for node in nodes.dropFirst() { groups.join(nodes[0], node) }
        }
        for track in board.tracks where !routeTrackIDs.contains(track.id) {
            let from = Key(track.from), to = Key(track.to)
            for layer in track.layer.map({ [$0] }) ?? allLayers {
                groups.join(Node(key: from, layer: layer), Node(key: to, layer: layer))
            }
        }
        for via in board.vias {
            joinAll(Key(via.position), viaLayers(via, in: board))
        }
        for hole in board.packageHoles {
            joinAll(Key(hole.position), nil)
        }
        let padLayers = padLayers(in: board, allLayers: allLayers)
        for (path, center) in board.packagePadPositions {
            joinAll(Key(center), padLayers[normalizedID(path)] ?? [])
        }
        let ends = (layers(at: end, in: board).map(Array.init) ?? allLayers).map { groups.root(Node(key: endKey, layer: $0)) }
        return (layers(at: start, in: board).map(Array.init) ?? allLayers).contains { layer in
            ends.contains(groups.root(Node(key: startKey, layer: layer)))
        }
    }

    /// Takes `tracks` and `vias` off `board`, each via with its hole, and
    /// records the vias as removed for the writer, which keeps a via entry
    /// the model lacks. The junctions they leave joining nothing go with the
    /// connectivity pass the route's commit runs.
    static func remove(tracks trackIDs: [String], vias viaIDs: [String], from board: inout HorizontalBoard) {
        let tracks = Set(trackIDs.map(normalizedID))
        if !tracks.isEmpty {
            board.tracks.removeAll { tracks.contains(normalizedID($0.id)) }
        }
        let vias = Set(viaIDs.map(normalizedID))
        guard !vias.isEmpty else {
            return
        }
        board.vias.removeAll { vias.contains(normalizedID($0.id)) }
        board.viaHoles.removeAll { hole in
            let id = normalizedID(hole.id)
            return vias.contains(id) || vias.contains { id.hasPrefix("\($0)/") }
        }
        board.removedViaIDs.formUnion(viaIDs)
    }

    // MARK: - Helpers

    /// Copper other than the route's at `point`: a pad, a via or a hole
    /// there, or a track ending there on `layer`.
    private static func touchesCopper(
        _ point: HorizontalPoint,
        layer: Int,
        sparing routeTrackIDs: Set<String>,
        in board: HorizontalBoard
    ) -> Bool {
        let key = Key(point)
        return board.packagePadPositions.values.contains { Key($0) == key }
            || board.packageHoles.contains { Key($0.position) == key }
            || board.vias.contains { Key($0.position) == key }
            || board.tracks.contains { track in
                (Key(track.from) == key || Key(track.to) == key)
                    && layerMatches(track.layer, layer)
                    && !routeTrackIDs.contains(track.id)
            }
    }

    /// The copper layers joined at a stretch's end: the route's own, and
    /// those of any via, pad or hole there. Nil for all of them.
    private static func layers(at end: BoardTrackLoopEnd, in board: HorizontalBoard) -> Set<Int>? {
        let key = Key(end.point)
        if board.packageHoles.contains(where: { Key($0.position) == key }) {
            return nil
        }
        var layers: Set<Int> = [end.layer]
        for via in board.vias where Key(via.position) == key {
            guard let span = viaLayers(via, in: board) else { return nil }
            layers.formUnion(span)
        }
        let pads = board.packagePadPositions.filter { Key($0.value) == key }.map { normalizedID($0.key) }
        guard !pads.isEmpty else {
            return layers
        }
        let allLayers = BoardTrackRouting.throughViaLayers(copperLayerCount: board.copperLayerCount)
        let padLayers = padLayers(in: board, allLayers: allLayers)
        for pad in pads {
            layers.formUnion(padLayers[pad] ?? [])
        }
        return layers
    }

    /// Each pad's copper layers, by its path ("package/pad"); a shape with no
    /// layer is on all of them.
    private static func padLayers(in board: HorizontalBoard, allLayers: [Int]) -> [String: Set<Int>] {
        var layers = [String: Set<Int>]()
        for polygon in board.packagePads {
            guard let path = BoardTrackRouting.padPath(forPolygonID: polygon.id) else { continue }
            if let layer = polygon.layer {
                if HorizontalBoardLayers.isCopper(layer) { layers[path, default: []].insert(layer) }
            } else {
                layers[path, default: []].formUnion(allLayers)
            }
        }
        return layers
    }

    /// The copper layers a via joins; nil, for all of them, when it lists none.
    private static func viaLayers(_ via: HorizontalMarker, in board: HorizontalBoard) -> Set<Int>? {
        let listed = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
        return listed.isEmpty ? nil : Set(listed)
    }

    /// Whether a via inside a chain only passes it on: one that stands in a
    /// plane's fill on a layer it reaches joins the plane too.
    private static func passes(_ via: HorizontalMarker, in board: HorizontalBoard) -> Bool {
        let span = viaLayers(via, in: board)
        return !board.planes.contains { plane in
            layersContain(span, plane.layer)
                && plane.renderFragments.contains { fragment in
                    fragment.containmentPaths.filter { $0.contains(via.position) }.count % 2 == 1
                }
        }
    }

    /// A track with no layer spans every layer.
    private static func layerMatches(_ trackLayer: Int?, _ layer: Int) -> Bool {
        trackLayer.map { $0 == layer } ?? true
    }

    private static func layersContain(_ layers: Set<Int>?, _ layer: Int?) -> Bool {
        guard let layers, let layer else { return true }
        return layers.contains(layer)
    }

    private static func normalizedID(_ id: String) -> String {
        HorizontalCanvasModeSupport.normalizedID(id)
    }

    /// One point on one copper layer.
    private struct Node: Hashable {
        var key: Key
        var layer: Int
    }

    /// Which nodes copper joins, as disjoint sets.
    private struct Groups {
        private var parent = [Node: Node]()

        mutating func root(_ node: Node) -> Node {
            var top = node
            while let next = parent[top], next != top {
                top = next
            }
            var walk = node
            while let next = parent[walk], next != top {
                parent[walk] = top
                walk = next
            }
            return top
        }

        mutating func join(_ a: Node, _ b: Node) {
            let ra = root(a), rb = root(b)
            if ra != rb {
                parent[ra] = rb
            }
        }
    }

    /// A point rounded to the nanometre, as connectivity keys points.
    private struct Key: Hashable {
        let x: Int64
        let y: Int64

        init(_ point: HorizontalPoint) {
            x = Int64(point.x.rounded())
            y = Int64(point.y.rounded())
        }
    }
}
