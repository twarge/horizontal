import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Meander tuning on a board: cells sized to the room the board leaves,
/// clearance-checked on their swept boxes, laid as tracks and junctions the
/// writer keeps, and checked again on the exact shapes; on synthetic copper
/// and on Board B's real board.
final class HorizontalMeanderTunerTests: XCTestCase {
    private let mm = 1_000_000.0
    private let netA = "aaaaaaaa-0000-4000-8000-000000000001"
    private let netB = "bbbbbbbb-0000-4000-8000-000000000002"

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func track(_ id: String, _ from: (Double, Double), _ to: (Double, Double), net: String?,
                       width: Double = 200_000) -> HorizontalSegment {
        HorizontalSegment(id: id, from: p(from.0, from.1), to: p(to.0, to.1), width: width,
                          layer: HorizontalBoardLayers.topCopper, netID: net)
    }

    private func board(_ tracks: [HorizontalSegment]) -> HorizontalBoard {
        let bounds = HorizontalRect(points: [.zero, p(40, 40)])
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/meander.hprj"), uuid: "b", name: "meander",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: [:], junctionNetIDs: [:],
            netDetails: [netA: HorizontalNetDetails(id: netA, name: "A"), netB: HorizontalNetDetails(id: netB, name: "B")],
            tracks: tracks,
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: bounds, bounds: bounds
        )
    }

    private func settings(_ amplitude: Double = 1.5, corner: HorizontalMeander.Corner = .chamfer) -> HorizontalMeander.Settings {
        var settings = HorizontalMeander.Settings()
        settings.amplitude = amplitude * mm
        settings.corner = corner
        return settings
    }

    /// The lengths of the net's tracks on `board`, arcs along their circles.
    private func netLength(_ board: HorizontalBoard, _ net: String) -> Double {
        HorizontalTrackLength.routedLength(ofNet: net, in: board.tracks)
    }

    func testCellsGoWhereThereIsRoomAndClearEverything() throws {
        // A wall of another net a millimetre above: the cells go below.
        var tuned = board([track("t", (5, 10), (35, 10), net: netA), track("wall", (5, 11), (35, 11), net: netB)])
        let tuner = HorizontalMeanderTuner(board: tuned)
        let target = 30 * mm + 4 * mm
        let result = tuner.tune(.init(trackID: "t", anchor: p(6, 10), cursor: p(34, 10.5), target: target, settings: settings()))
        XCTAssertEqual(result.status, .reached)
        XCTAssertEqual(result.netLength, 30 * mm, accuracy: 1e-6)
        XCTAssertEqual(result.tunedLength, target, accuracy: 2)
        XCTAssertTrue(result.plan.cells.allSatisfy { $0.side == -1 }, "the cursor's side is blocked: \(result.plan.cells)")

        let ids = HorizontalMeanderTuner.lay(result, on: &tuned)
        XCTAssertEqual(ids.count, result.pieces.count)
        XCTAssertNil(tuned.tracks.first { $0.id == "t" }, "the track is replaced")
        XCTAssertEqual(netLength(tuned, netA), result.tunedLength, accuracy: 1e-3, "laid as measured")
        XCTAssertEqual(HorizontalMeanderTuner.violations(on: tuned, newTrackIDs: ids), [])
        // A junction at every meeting of two pieces, on the net.
        XCTAssertEqual(tuned.junctions.count, result.pieces.count - 1)
        XCTAssertTrue(tuned.junctionNetIDs.values.allSatisfy { $0 == netA })
    }

    /// The check isn't vacuous: cells laid with no regard for the room, up
    /// into a wall, are found.
    func testTheExactCheckFindsCellsLaidIntoCopper() throws {
        var tuned = board([track("t", (5, 10), (35, 10), net: netA), track("wall", (5, 10.8), (35, 10.8), net: netB)])
        let lattice = try XCTUnwrap(HorizontalMeander.lattice(from: p(5, 10), to: p(35, 10)))
        let slots = HorizontalMeander.slots(lattice: lattice, anchor: 0, toward: lattice.steps,
                                            spacing: 600_000, corner: 150_000, margin: 750_000)
        var oneSide = settings(1)
        oneSide.style = .oneSided
        let plan = HorizontalMeander.plan(needed: 3 * mm, lattice: lattice, slots: slots, settings: oneSide, side: 1,
                                          minimumAmplitude: 200_000) { _, _ in .max }
        let pieces = HorizontalMeander.pieces(lattice: lattice, cells: plan.cells, corner: .chamfer)
        let request = HorizontalMeanderTuner.Request(trackID: "t", anchor: p(5, 10), cursor: p(35, 11), target: 33 * mm,
                                                     settings: oneSide)
        let forced = HorizontalMeanderTuner.Result(request: request, netID: netA, layer: 0, lattice: lattice, plan: plan,
                                                   pieces: pieces, netLength: 30 * mm, tunedLength: 33 * mm, status: .reached)
        let ids = HorizontalMeanderTuner.lay(forced, on: &tuned)
        XCTAssertFalse(HorizontalMeanderTuner.violations(on: tuned, newTrackIDs: ids).isEmpty)
    }

    func testCellsShrinkBetweenWallsAndStayClear() throws {
        // Walls on both sides, 0.9 mm off: the cells are as tall as the room
        // between, and more of them make up the length.
        var tuned = board([track("t", (5, 10), (35, 10), net: netA), track("above", (5, 10.9), (35, 10.9), net: netB),
                           track("below", (5, 9.1), (35, 9.1), net: netB)])
        let tuner = HorizontalMeanderTuner(board: tuned)
        let result = tuner.tune(.init(trackID: "t", anchor: p(5, 10), cursor: p(35, 10.2),
                                      target: 33 * mm, settings: settings()))
        XCTAssertEqual(result.status, .reached, "\(result.plan)")
        let tallest = try XCTUnwrap(result.plan.cells.map(\.amplitude).max())
        XCTAssertLessThan(Double(tallest), 0.9 * mm - 0.2 * mm, "shrunk to the room")
        let ids = HorizontalMeanderTuner.lay(result, on: &tuned)
        XCTAssertEqual(HorizontalMeanderTuner.violations(on: tuned, newTrackIDs: ids), [])
    }

    func testAnObstacleInTheWayDropsOrShrinksOnlyItsCell() throws {
        // A short stub of another net 0.6 mm above the middle of the track.
        var tuned = board([track("t", (5, 10), (35, 10), net: netA), track("stub", (19, 10.6), (21, 10.6), net: netB)])
        var serpentine = settings()
        serpentine.style = .serpentine
        let tuner = HorizontalMeanderTuner(board: tuned)
        let result = tuner.tune(.init(trackID: "t", anchor: p(5, 10), cursor: p(35, 10.5),
                                      target: 30 * mm + 12 * mm, settings: serpentine))
        let ids = HorizontalMeanderTuner.lay(result, on: &tuned)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(HorizontalMeanderTuner.violations(on: tuned, newTrackIDs: ids), [])
        XCTAssertTrue(result.plan.cells.contains { $0.side == 1 }, "the left still takes cells away from the stub")
    }

    func testItSaysWhenThereIsNothingToDo() throws {
        let plain = board([track("t", (5, 10), (35, 10), net: netA), track("arc", (5, 20), (7, 22), net: netA)])
        let tuner = HorizontalMeanderTuner(board: plain)
        let longer = tuner.tune(.init(trackID: "t", anchor: p(5, 10), cursor: p(35, 11), target: 20 * mm, settings: settings()))
        XCTAssertEqual(longer.status, .longEnough)
        XCTAssertFalse(longer.hasCells)
        var curved = plain
        curved.tracks[1].center = p(5, 22)
        let arc = HorizontalMeanderTuner(board: curved).tune(
            .init(trackID: "arc", anchor: p(5, 20), cursor: p(7, 22), target: 50 * mm, settings: settings()))
        XCTAssertEqual(arc.status, .notStraight)
        let odd = HorizontalMeanderTuner(board: board([track("odd", (0, 0), (3, 1), net: netA)])).tune(
            .init(trackID: "odd", anchor: .zero, cursor: p(3, 1), target: 10 * mm, settings: settings()))
        XCTAssertEqual(odd.status, .notStraight)
        // Too short a stretch: what is missing.
        let short = tuner.tune(.init(trackID: "t", anchor: p(10, 10), cursor: p(12, 11), target: 60 * mm, settings: settings()))
        guard case .short(let missing) = short.status else { return XCTFail("\(short.status)") }
        XCTAssertEqual(missing, 60 * mm - short.tunedLength, accuracy: 1e-6)
        XCTAssertEqual(tuner.track(near: p(20, 10.05), reach: 100_000)?.id, "t")
        XCTAssertNil(tuner.track(near: p(20, 12), reach: 100_000))
    }

    func testADiagonalTrackTunesInWholeNanometres() throws {
        let tuned = board([track("d", (5, 5), (25, 25), net: netA)])
        let tuner = HorizontalMeanderTuner(board: tuned)
        let base = 20 * 2.squareRoot() * mm
        for corner in HorizontalMeander.Corner.allCases {
            let result = tuner.tune(.init(trackID: "d", anchor: p(5, 5), cursor: p(24, 26), target: base + 5 * mm,
                                          settings: settings(1, corner: corner)))
            XCTAssertEqual(result.status, .reached, "\(corner)")
            XCTAssertEqual(result.tunedLength, base + 5 * mm, accuracy: 3)
            var laid = tuned
            let ids = HorizontalMeanderTuner.lay(result, on: &laid)
            for track in laid.tracks where ids.contains(track.id) {
                for point in [track.from, track.to] + [track.center].compactMap({ $0 }) {
                    XCTAssertEqual(point.x, point.x.rounded())
                    XCTAssertEqual(point.y, point.y.rounded())
                }
            }
            XCTAssertEqual(HorizontalMeanderTuner.violations(on: laid, newTrackIDs: ids), [])
        }
    }

    /// Written to the board file and read back, the meander is the same
    /// copper: its tracks, its arcs, its junctions and its length.
    func testALaidTuneRoundTripsThroughTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-meander-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        var project = try HorizontalProject.load(from: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        var json = try JSONHelper.loadDictionary(from: try XCTUnwrap(archive.regularFileData(relativePath: "board.json")))
        json["junctions"] = ["j-from": ["position": [5_000_000, 5_000_000]], "j-to": ["position": [25_000_000, 5_000_000]]]
        json["tracks"] = ["t": ["from": ["junc": "j-from", "pad": NSNull()], "to": ["junc": "j-to", "pad": NSNull()],
                                "width": 200_000, "layer": 0, "width_from_net_class": false, "locked": false]]
        try archive.replaceRegularFileData(relativePath: "board.json", with: try JSONSerialization.data(withJSONObject: json))
        var loaded = try HorizontalProject.loadSnapshot(of: archive)
        loaded.rebaseURLs(onto: project)
        project = loaded
        var board = try XCTUnwrap(project.board)
        XCTAssertEqual(board.tracks.map(\.id), ["t"])

        let tuner = HorizontalMeanderTuner(board: board)
        let result = tuner.tune(.init(trackID: "t", anchor: p(5, 5), cursor: p(25, 6), target: 26 * mm,
                                      settings: settings(1, corner: .arc)))
        XCTAssertEqual(result.status, .reached)
        HorizontalMeanderTuner.lay(result, on: &board)
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive))
        let reloaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertEqual(reloaded.tracks.count, result.pieces.count)
        XCTAssertEqual(reloaded.tracks.filter { $0.center != nil }.count, 4 * result.plan.cells.count)
        XCTAssertEqual(reloaded.tracks.reduce(0) { $0 + HorizontalTrackLength.length(of: $1) }, 26 * mm, accuracy: 2)
        // Every end on a junction: the ends the track had, and one between each two pieces.
        let ends = reloaded.tracks.flatMap { [$0.fromJunctionID, $0.toJunctionID] }
        XCTAssertFalse(ends.contains(nil), "\(reloaded.tracks)")
        XCTAssertTrue(Set(ends.compactMap { $0 }).isSuperset(of: ["j-from", "j-to"]))
    }

    /// Board B, whose TX±, RX± and PPS In± are paired: each straight track
    /// of a few millimetres on a net is tuned a millimetre longer, and what is
    /// laid never breaks a clearance rule on the exact shapes.
    func testRealBoardTunesBreakNoRule() throws {
        let path = ProcessInfo.processInfo.environment["HORIZONTAL_GOLDEN_BOARD"]
            ?? "/Users/kornack/Repositories/board b/Board B Horizon/Board B.hprj"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no real board available")
        }
        let board = try XCTUnwrap(HorizontalProject.load(from: URL(fileURLWithPath: path)).board)
        let paired = Set(board.netDetails.values.filter { $0.diffpairID != nil }.map(\.id))
        XCTAssertGreaterThanOrEqual(paired.count, 6, "TX±, RX± and PPS In±")
        // The pairs' tracks first, then others, sorted so the sample is the same every run.
        let candidates = board.tracks
            .filter { $0.center == nil && $0.netID != nil && HorizontalMeander.lattice(from: $0.from, to: $0.to) != nil }
            .filter { HorizontalTrackLength.length(of: $0) >= 4 * mm }
            .sorted { (paired.contains($0.netID!.lowercased()) ? 0 : 1, $0.id) < (paired.contains($1.netID!.lowercased()) ? 0 : 1, $1.id) }
            .prefix(16)
        XCTAssertFalse(candidates.isEmpty)
        let tuner = HorizontalMeanderTuner(board: board)
        var settings = HorizontalMeander.Settings()
        settings.amplitude = 0.6 * mm
        settings.spacing = 0.45 * mm
        var tuned = 0, reached = 0, slowest = 0.0
        for track in candidates {
            let normal = HorizontalPoint(x: -(track.to.y - track.from.y), y: track.to.x - track.from.x)
            let scale = 0.5 * mm / max(hypot(normal.x, normal.y), 1)
            let cursor = HorizontalPoint(x: track.to.x + normal.x * scale, y: track.to.y + normal.y * scale)
            let start = Date()
            let result = tuner.tune(.init(trackID: track.id, anchor: track.from, cursor: cursor,
                                          target: tuner.netLength(track.netID) + 1 * mm, settings: settings))
            slowest = max(slowest, Date().timeIntervalSince(start))
            guard result.hasCells else { continue }
            tuned += 1
            if result.status == .reached { reached += 1 }
            var laid = board
            let ids = HorizontalMeanderTuner.lay(result, on: &laid)
            let violations = HorizontalMeanderTuner.violations(on: laid, newTrackIDs: ids)
            XCTAssertEqual(violations.map(\.id), [], "track \(track.id) on \(board.netDetails[track.netID!.lowercased()]?.name ?? "")")
        }
        print("Board B meanders: \(candidates.count) tracks, \(tuned) tuned, \(reached) reached a millimetre more, slowest \(Int(slowest * 1000)) ms")
        XCTAssertGreaterThan(tuned, 0, "some straight track has room")
    }
}
