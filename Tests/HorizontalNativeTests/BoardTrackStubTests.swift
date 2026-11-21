import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Track stubs on the board: a run of track with an end on nothing is a
/// warning of the rules check, at the dead end, with the run back to where it
/// branches or lands; an end that lies in copper, on a via or where a
/// connection line starts is none.
final class BoardTrackStubTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func mm(_ value: Double) -> Double { value * 1_000_000 }

    /// A 0.2 mm track of net A; its ends name the junctions given.
    private func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint, from: String? = nil, to: String? = nil,
                       net: String? = "net-a", layer: Int = HorizontalBoardLayers.topCopper) -> HorizontalSegment {
        var track = HorizontalSegment(id: id, from: a, to: b, width: mm(0.2), layer: layer, netID: net)
        track.fromJunctionID = from
        track.toJunctionID = to
        return track
    }

    private func square(_ center: HorizontalPoint, _ size: Double) -> [HorizontalPoint] {
        let half = mm(size) / 2
        return [HorizontalPoint(x: center.x - half, y: center.y - half), HorizontalPoint(x: center.x + half, y: center.y - half),
                HorizontalPoint(x: center.x + half, y: center.y + half), HorizontalPoint(x: center.x - half, y: center.y + half)]
    }

    private let outline = HorizontalPolygon(
        id: "outline",
        vertices: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 40_000_000, y: 0),
                   HorizontalPoint(x: 40_000_000, y: 40_000_000), HorizontalPoint(x: 0, y: 40_000_000)],
        layer: HorizontalBoardLayers.outline
    )

    /// A board of U1 with a 1 mm square pad of net A at each of `pads`, by
    /// name, which tracks ending at its centre are bound to.
    private func makeBoard(
        tracks: [HorizontalSegment],
        pads: [String: HorizontalPoint] = [:],
        vias: [HorizontalMarker] = [],
        planes: [HorizontalPlane] = [],
        connectionLines: [HorizontalSegment] = [],
        junctions: [String: HorizontalPoint] = [:]
    ) -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/track-stubs.hprj"), uuid: "b", name: "stubs",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_600_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 0),
            ],
            userLayers: [], junctions: junctions, junctionNetIDs: [:],
            netDetails: ["net-a": HorizontalNetDetails(id: "net-a", name: "A")],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: connectionLines, airwires: [],
            polygons: [outline], planes: planes, keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias, viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: p(10, 10), angle: 0, mirrored: false, label: "U1", componentID: "comp-u1")],
            packagePads: pads.sorted { $0.key < $1.key }.map { name, center in
                HorizontalPolygon(id: "pkg/pad/\(name)/shape/s1", vertices: square(center, 1), layer: top, netID: "net-a",
                                  metadata: ["Pad": name])
            },
            packageHoles: [], packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = Dictionary(uniqueKeysWithValues: pads.map { ("pkg/\($0.key)", $0.value) })
        // Only the copper checks that are Horizontal's own.
        board.takeRules([
            "preflight_checks": ["enabled": false], "board_connectivity": ["enabled": false],
            "net_ties": ["enabled": false], "height_restrictions": ["enabled": false],
            "clearance_silkscreen_exposed_copper": ["enabled": false],
        ])
        return board
    }

    private func stubs(_ board: HorizontalBoard) throws -> [HorizontalBoardRuleFinding] {
        let results = try XCTUnwrap(HorizontalBoardRulesCheck.run(board: board))
        return results.all.filter { $0.check == HorizontalBoardRulesCheck.trackStubCheck }
    }

    /// A track from a pad to a bare point is a warning at that point, among
    /// the Copper findings, naming its net, its layer and the pad it leaves.
    func testATrackFromAPadToNowhereIsAWarningAtItsFreeEnd() throws {
        let board = makeBoard(tracks: [track("t", p(10, 10), p(14, 10))], pads: ["1": p(10, 10)])
        let found = try stubs(board)
        XCTAssertEqual(found.count, 1, found.map(\.message).joined(separator: "\n"))
        let stub = try XCTUnwrap(found.first)
        XCTAssertNil(stub.kind)
        XCTAssertEqual(HorizontalBoardFindingSection.id(of: stub.kind), "copper")
        XCTAssertEqual(stub.level, .warning)
        XCTAssertEqual(stub.title, "Track ends on nothing")
        XCTAssertEqual(stub.message, "Track of A on \(HorizontalBoardLayers.name(for: top)) ends on nothing")
        XCTAssertEqual(stub.detail, "1 track, 4 mm from pad U1.1 to an end on no pad, via, other track or plane.")
        XCTAssertEqual(stub.location, p(14, 10))
        XCTAssertEqual(stub.objectIDs, ["t"])
        XCTAssertEqual(stub.layers, [top])
        XCTAssertEqual(stub.netIDs, ["net-a"])
        XCTAssertEqual(stub.netNames, ["A"])
        let region = try XCTUnwrap(stub.region)
        XCTAssertTrue(region.minX < p(10, 10).x && region.maxX > p(14, 10).x, "the whole run is framed")
    }

    /// A dead-end branch is followed back through its bend to the junction
    /// it leaves the net at, and no further: the tracks between the pads
    /// are no part of it.
    func testARunIsFollowedBackToWhereItBranches() throws {
        let board = makeBoard(
            tracks: [track("main-1", p(10, 10), p(15, 10), to: "j1"),
                     track("main-2", p(15, 10), p(20, 10), from: "j1"),
                     track("branch-1", p(15, 10), p(15, 13), from: "j1", to: "j2"),
                     track("branch-2", p(15, 13), p(17, 15), from: "j2", to: "j3")],
            pads: ["1": p(10, 10), "2": p(20, 10)],
            junctions: ["j1": p(15, 10), "j2": p(15, 13), "j3": p(17, 15)])
        let found = try stubs(board)
        XCTAssertEqual(found.count, 1, found.map(\.message).joined(separator: "\n"))
        let stub = try XCTUnwrap(found.first)
        XCTAssertEqual(stub.objectIDs, ["branch-2", "branch-1"], "from the dead end back")
        XCTAssertEqual(stub.location, p(17, 15))
        XCTAssertEqual(stub.detail, "2 tracks, 5.828 mm from where it branches to an end on no pad, via, other track or plane.")
    }

    /// A track the app has drawn names no junction till the file is read
    /// again, and ends where a track from the file names its own. The two
    /// are one run all the same: drawn on from a loaded track to nowhere, the
    /// stub is both, back to the pad; drawn on to a pad, there is none.
    func testADrawnTrackAndALoadedOneMeetingAtAJunctionAreOneRun() throws {
        let loaded = track("loaded", p(10, 10), p(14, 10), to: "j")
        let junctions = ["j": p(14, 10), "end": p(14, 13)]
        let found = try stubs(makeBoard(tracks: [loaded, track("drawn", p(14, 10), p(14, 13))], pads: ["1": p(10, 10)],
                                        junctions: junctions))
        XCTAssertEqual(found.map(\.objectIDs), [["drawn", "loaded"]], found.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(found.first?.location, p(14, 13))
        XCTAssertEqual(found.first?.detail, "2 tracks, 7 mm from pad U1.1 to an end on no pad, via, other track or plane.")

        let landed = makeBoard(tracks: [loaded, track("drawn", p(14, 10), p(20, 10))], pads: ["1": p(10, 10), "2": p(20, 10)],
                               junctions: junctions)
        XCTAssertEqual(try stubs(landed).map(\.message), [])
        XCTAssertEqual(HorizontalBoardTrackStubs.stubs(of: landed).count, 0, "no end is alone on its junction")
    }

    /// Tracks on two layers that end at one point with no via there join
    /// nothing, though a junction is at the point: each end is a dead end.
    /// With a via they are joined, and the stub is what is left past it.
    func testTracksOnTwoLayersMeetOnlyThroughAVia() throws {
        let tracks = [track("top", p(10, 10), p(14, 10)), track("under", p(14, 10), p(14, 13), layer: bottom)]
        let junctions = ["j": p(14, 10), "end": p(14, 13)]
        let apart = try stubs(makeBoard(tracks: tracks, pads: ["1": p(10, 10)], junctions: junctions))
        XCTAssertEqual(Set(apart.map(\.objectIDs)), [["top"], ["under"]], apart.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(apart.first { $0.objectIDs == ["under"] }?.message,
                       "Track of A on \(HorizontalBoardLayers.name(for: bottom)) joins nothing")

        let via = HorizontalMarker(id: "v", position: p(14, 10), size: mm(0.6), holeSize: mm(0.3), layer: top,
                                   connectedLayers: [top, bottom], netID: "net-a")
        let joined = try stubs(makeBoard(tracks: tracks, pads: ["1": p(10, 10)], vias: [via], junctions: junctions))
        XCTAssertEqual(joined.map(\.objectIDs), [["under"]])
        XCTAssertEqual(joined.first?.detail, "1 track, 3 mm from a via to an end on no pad, via, other track or plane.")
    }

    /// Track with neither end on anything joins nothing, and is one finding,
    /// not one an end.
    func testTrackWithBothEndsFreeJoinsNothing() throws {
        let board = makeBoard(tracks: [track("a", p(10, 20), p(12, 20), to: "j"), track("b", p(12, 20), p(12, 23), from: "j")],
                              junctions: ["j": p(12, 20)])
        let found = try stubs(board)
        XCTAssertEqual(found.count, 1, found.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(found.first?.message, "Track of A on \(HorizontalBoardLayers.name(for: top)) joins nothing")
        XCTAssertEqual(found.first?.detail, "2 tracks, 5 mm long, with neither end on a pad, a via, another track or a plane.")
        XCTAssertEqual(Set(found.first?.objectIDs ?? []), ["a", "b"])
    }

    /// An end that names no junction with anything can still be in copper,
    /// and is then no dead end: off the centre of a pad, across another
    /// track, inside its plane's fill. Nor is an end on a via.
    func testAnEndInCopperOrOnAViaIsNoStub() throws {
        let via = HorizontalMarker(id: "v", position: p(30, 14), size: mm(0.6), holeSize: mm(0.3), layer: top,
                                   connectedLayers: [top, bottom], netID: "net-a")
        let fill = square(p(30, 30), 6)
        let plane = HorizontalPlane(
            id: "pour", netID: "net-a", polygonID: "pour-polygon", layer: top, priority: 0, fillStyle: "solid",
            minWidth: 0, keepOrphans: false, fragments: [HorizontalPlaneFragment(paths: [fill], orphan: false)],
            fallbackPolygon: HorizontalPolygon(id: "pour-polygon", vertices: fill, layer: top))
        let board = makeBoard(
            tracks: [track("pad-to-pad", p(10, 10), p(20, 10)),
                     // To a point 0.3 mm off pad 3's centre, still inside it.
                     track("off-centre", p(10, 10), p(10.3, 19.8)),
                     // Onto the middle of the first track, which has no junction there.
                     track("tee", p(15, 14), p(15, 10)),
                     // The tee's other end, on a via with the track to the fill.
                     track("to-via", p(15, 14), p(30, 14)),
                     track("into-fill", p(30, 14), p(30, 28))],
            pads: ["1": p(10, 10), "2": p(20, 10), "3": p(10, 20)],
            vias: [via], planes: [plane])
        XCTAssertEqual(try stubs(board).map(\.message), [])
        // The tee is found as a run by its junctions all the same, on to
        // the via, for find_stubs to say what its end lies in.
        let runs = HorizontalBoardTrackStubs.stubs(of: board)
        let tee = try XCTUnwrap(runs.first { $0.tracks.map(\.id) == ["tee", "to-via"] }, "\(runs.map { $0.tracks.map(\.id) })")
        XCTAssertEqual(tee.far.touch, .via("v"))
        XCTAssertFalse(tee.isDeadEnd)
        XCTAssertEqual(tee.free.liesIn, ["Track pad-to-pad"])
    }

    /// The same end with the fill gone from under it is a dead end again:
    /// the check reads the fills as last poured.
    func testAnEndWhereNoFillIsPouredIsAStub() throws {
        let via = HorizontalMarker(id: "v", position: p(30, 14), size: mm(0.6), holeSize: mm(0.3), layer: top,
                                   connectedLayers: [top, bottom], netID: "net-a")
        let board = makeBoard(tracks: [track("to-via", p(10, 10), p(30, 14)), track("into-fill", p(30, 14), p(30, 28))],
                              pads: ["1": p(10, 10)], vias: [via])
        let found = try stubs(board)
        XCTAssertEqual(found.map(\.objectIDs), [["into-fill"]])
        XCTAssertEqual(found.first?.detail, "1 track, 14 mm from a via to an end on no pad, via, other track or plane.")
    }

    /// A connection line says its ends are joined by something the board
    /// doesn't draw, so a track that stops where one starts ends on that.
    func testAnEndAConnectionLineStartsFromIsJoined() throws {
        let stub = track("t", p(10, 10), p(14, 10))
        let link = HorizontalSegment(id: "link", from: p(14, 10), to: p(24, 10), width: 0, layer: nil, netID: "net-a")
        XCTAssertEqual(try stubs(makeBoard(tracks: [stub], pads: ["1": p(10, 10)])).count, 1)
        XCTAssertEqual(try stubs(makeBoard(tracks: [stub], pads: ["1": p(10, 10)], connectionLines: [link])).count, 0)
    }

    /// The canvas marks a stub in yellow at its dead end and strokes the
    /// outline of the whole run in orange, as it does copper joining two nets.
    func testAStubIsMarkedAsAWarningWithItsRunOutlined() throws {
        let board = makeBoard(tracks: [track("a", p(10, 10), p(14, 10), to: "j"), track("b", p(14, 10), p(14, 13), from: "j")],
                              pads: ["1": p(10, 10)], junctions: ["j": p(14, 10)])
        let stub = try XCTUnwrap(try stubs(board).first)
        XCTAssertFalse(stub.highlights.isEmpty)
        let points = stub.highlights.flatMap { $0 }
        let box = HorizontalRect(points: points)
        // Round both tracks: 0.1 mm past their centrelines on every side.
        XCTAssertEqual(box.minX, p(10, 10).x - mm(0.1), accuracy: 10_000)
        XCTAssertEqual(box.maxX, p(14, 10).x + mm(0.1), accuracy: 10_000)
        XCTAssertEqual(box.minY, p(10, 10).y - mm(0.1), accuracy: 10_000)
        XCTAssertEqual(box.maxY, p(14, 13).y + mm(0.1), accuracy: 10_000)

        let marker = try XCTUnwrap(HorizontalCanvasWarning.markers(boardFindings: [stub]).first)
        XCTAssertEqual(marker.position, p(14, 13))
        XCTAssertFalse(marker.isError, "a warning's marker is yellow")
        XCTAssertEqual(marker.highlights, stub.highlights)
        XCTAssertEqual(marker.messages, [stub.text])
    }
}
