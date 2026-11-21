import Foundation

/// A run of track with an end on nothing: the tracks from that end on,
/// through junctions of two tracks, to where the run branches, lands on a pad
/// or a via, or ends again.
struct HorizontalTrackStub {
    /// What an end of a run is on.
    struct End {
        enum Touch: Equatable {
            /// A pad, by its "package/pad" path, lowercased.
            case pad(String)
            /// A via, by its id.
            case via(String)
            /// A junction other tracks end on: how many tracks do, this one
            /// among them.
            case junction(tracks: Int)
            /// Nothing the junctions name.
            case nothing
        }

        var position: HorizontalPoint
        var touch: Touch
        /// The copper an end that touches nothing lies in all the same,
        /// sorted: "Track <id>", or the item's label ("Pad U3.4", "Plane").
        var liesIn: [String] = []

        /// On no pad, via or junction, and in no copper.
        var isFree: Bool { touch == .nothing && liesIn.isEmpty }
    }

    /// The run's tracks, from the free end on.
    var tracks: [HorizontalSegment]
    /// The end the run was found by, alone on its junction.
    var free: End
    /// Where the run stops.
    var far: End

    /// Lowercased.
    var netID: String? { tracks.first?.netID?.lowercased() }

    var length: Double {
        tracks.reduce(0) { $0 + HorizontalRoute45.length(of: $1.pathPoints) }
    }

    /// The free end lies in no copper either, so the run carries nothing.
    /// One that does lie in copper may be joining its net there, though no
    /// junction says so.
    var isDeadEnd: Bool { free.liesIn.isEmpty }

    /// A dead end at both ends: track that joins nothing at all.
    var joinsNothing: Bool { isDeadEnd && far.isFree }
}

/// The board's track stubs, which the rules check lists as findings
/// (`HorizontalBoardRulesCheck.trackStubFindings`) and `find_stubs` reports
/// with what each end touches.
///
/// What an end touches is said twice over, by the netlist of junctions and by
/// the copper: a run whose free end is on no junction with anything else can
/// still lie in a pad or across a track of its net, and is then carrying
/// current. Removing one of those for a stub breaks a connection.
enum HorizontalBoardTrackStubs {
    /// Every run of track with an end alone on a plain junction, in a set
    /// order. `items` is the board's, where the caller has them already; they
    /// are built only once an end has to be looked for in the copper.
    static func stubs(of board: HorizontalBoard, items given: HorizontalBoardItems? = nil) -> [HorizontalTrackStub] {
        func key(_ point: HorizontalPoint) -> String { HorizontalBoard.junctionPointKey(point) }

        var padAt = [String: String]()
        for (path, point) in board.packagePadPositions { padAt[key(point)] = path.lowercased() }
        var viaAt = [String: HorizontalMarker]()
        for via in board.vias { viaAt[key(via.position)] = via }

        // A track the app has drawn names no junction until it is saved and
        // read again, and ends where one loaded from the file names its own.
        let junctionsAt = board.junctionIDsByPoint()
        let junctionLayers = board.junctionLayers()

        /// What a track's end is on: the junction it names, the pad it is
        /// bound to, or, naming neither, the junction at its point that
        /// tracks on its layer name; failing all three, its point on its
        /// layer, which it shares with the other ends that name nothing
        /// there. Never a junction only copper on another layer is on: with
        /// no via, that joins nothing.
        struct Node: Hashable { var id: String }
        func node(_ track: HorizontalSegment, _ first: Bool) -> Node {
            if let junction = first ? track.fromJunctionID : track.toJunctionID { return Node(id: "j:" + junction.lowercased()) }
            let point = first ? track.from : track.to
            if let pad = padAt[key(point)] { return Node(id: "p:" + pad) }
            if let layer = track.layer,
               let junction = junctionsAt[key(point)]?.first(where: { junctionLayers[$0.lowercased()]?.contains(layer) == true }) {
                return Node(id: "j:" + junction.lowercased())
            }
            return Node(id: "x:" + key(point) + ":\(track.layer ?? 0)")
        }
        var ends = [Node: [(track: Int, first: Bool)]]()
        var position = [Node: HorizontalPoint]()
        for (index, track) in board.tracks.enumerated() {
            for first in [true, false] {
                let at = node(track, first)
                ends[at, default: []].append((index, first))
                position[at] = first ? track.from : track.to
            }
        }
        /// A run passes through a plain junction only: not a pad, not a via.
        func isPlain(_ at: Node) -> Bool {
            !at.id.hasPrefix("p:") && viaAt[key(position[at] ?? .zero)] == nil
        }

        var catalog = given
        func end(_ at: Node, layer: Int?, excluding chain: Set<String>) -> HorizontalTrackStub.End {
            let point = position[at] ?? .zero
            var end = HorizontalTrackStub.End(position: point, touch: .nothing)
            if at.id.hasPrefix("p:") {
                end.touch = .pad(String(at.id.dropFirst(2)))
            } else if let via = viaAt[key(point)] {
                end.touch = .via(via.id)
            } else if let count = ends[at]?.count, count > 1 {
                end.touch = .junction(tracks: count)
            } else if let layer {
                // The copper the end lies in, whatever the junctions say.
                let items = catalog ?? HorizontalBoardItems(board: board)
                catalog = items
                let here = HorizontalBoardItem.Shape.disc(point, radius: 0)
                var lying = Set<String>()
                for index in items.indices(overlapping: HorizontalRouteClearanceProbe.bounds([point], growth: 1)) {
                    let item = items.items[index]
                    guard item.isOn(layer), item.kind.isCopper, !chain.contains(item.id.lowercased()),
                          HorizontalShapeGap.between(here, item.shape, limit: 0) != nil else { continue }
                    lying.insert(item.kind == .track ? "Track \(item.id)" : item.label)
                }
                end.liesIn = lying.sorted()
            }
            return end
        }

        // Dead ends: an end alone on a plain junction. The run is walked on
        // through junctions of two tracks to where it branches, lands or ends.
        var stubs = [HorizontalTrackStub]()
        var walked = Set<Int>()
        let starts = ends.filter { $0.value.count == 1 && isPlain($0.key) }.sorted { $0.key.id < $1.key.id }
        for (start, list) in starts {
            var tracks = [Int]()
            var at = start
            var next = list[0]
            while true {
                guard walked.insert(next.track).inserted else { break }
                tracks.append(next.track)
                at = node(board.tracks[next.track], !next.first)
                let others = (ends[at] ?? []).filter { $0.track != next.track }
                guard others.count == 1, isPlain(at) else { break }
                next = others[0]
            }
            guard !tracks.isEmpty else { continue }
            let segments = tracks.map { board.tracks[$0] }
            let ids = Set(segments.map { $0.id.lowercased() })
            stubs.append(HorizontalTrackStub(
                tracks: segments,
                free: end(start, layer: segments.first?.layer, excluding: ids),
                far: end(at, layer: segments.last?.layer, excluding: ids)))
        }
        return stubs
    }
}

extension HorizontalBoardRulesCheck {
    /// The key of the track stub check's findings, as `check` and a dry
    /// run's `check_ignore` name them.
    static let trackStubCheck = "track_stub"

    /// Horizontal's own check of tracks that go nowhere, a warning each: a
    /// run of track with an end on no pad, via or other track and in no
    /// copper, a plane's fill as last poured included. What is left of a
    /// route that was taken up, or a route not finished; Horizon has no
    /// check for either. An end a connection line starts from is joined on
    /// purpose, by what the board doesn't draw.
    static func trackStubFindings(board: HorizontalBoard) -> [HorizontalBoardRuleFinding] {
        let stubs = HorizontalBoardTrackStubs.stubs(of: board).filter(\.isDeadEnd)
        guard !stubs.isEmpty else { return [] }
        let connected = Set(board.connectionLines.flatMap { [$0.from, $0.to] }.map(HorizontalBoard.junctionPointKey))
        let names = padNames(board)
        var findings = [HorizontalBoardRuleFinding]()
        for stub in stubs {
            let ends = stub.joinsNothing ? [stub.free, stub.far] : [stub.free]
            guard !ends.contains(where: { connected.contains(HorizontalBoard.junctionPointKey($0.position)) }) else { continue }
            let net = netName(stub.netID, in: board)
            let layer = stub.tracks.first?.layer
            let place = layer.map { " on \(HorizontalBoardLayers.name(for: $0))" } ?? ""
            let run = "\(stub.tracks.count) track\(stub.tracks.count == 1 ? "" : "s"), \(HorizontalMillimetres.short(stub.length))"
            let detail: String
            if stub.joinsNothing {
                detail = "\(run) long, with neither end on a pad, a via, another track or a plane."
            } else {
                let origin: String
                switch stub.far.touch {
                case .pad(let path): origin = "pad \(names[path] ?? path)"
                case .via: origin = "a via"
                case .junction: origin = "where it branches"
                case .nothing: origin = "copper it shares no junction with"
                }
                detail = "\(run) from \(origin) to an end on no pad, via, other track or plane."
            }
            let points = stub.tracks.flatMap(\.pathPoints)
            findings.append(HorizontalBoardRuleFinding(
                kind: nil, level: .warning, check: trackStubCheck, title: "Track ends on nothing",
                message: "Track of \(net)\(place) \(stub.joinsNothing ? "joins nothing" : "ends on nothing")",
                detail: detail,
                location: stub.free.position, region: region(points),
                layers: Array(Set(stub.tracks.compactMap(\.layer))).sorted(by: >),
                netIDs: stub.netID.map { [$0] } ?? [], netNames: [net],
                objectIDs: stub.tracks.map(\.id),
                highlights: highlights(of: stub)))
        }
        return findings
    }
}
