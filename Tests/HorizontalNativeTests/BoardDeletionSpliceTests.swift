import XCTest
@testable import HorizontalNative

/// A delete that takes only copper off the board is spliced out of the scene
/// already built, the copper whose net it changed drawn again; anything else
/// it did has no splice, and the scene is built as before.
final class BoardDeletionSpliceTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private func p(_ x: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: 10 * mm) }

    /// Pad a1 on n at 0 mm, and a chain of tracks from it along y = 10 mm:
    /// t1 to j1 at 10, t2 to j2 at 20, t3 to j3 at 30, where nothing else is.
    /// Pad b1 on n at 40 mm is joined to nothing. A via v on n stands at j3.
    private func board() -> HorizontalBoard {
        func pad(_ package: String, _ name: String, at center: HorizontalPoint) -> HorizontalPolygon {
            let half = 0.4 * mm
            return HorizontalPolygon(id: "\(package)/pad/\(name)/shape/s", vertices: [
                .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
                .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
            ], layer: top, netID: "n")
        }
        func track(_ id: String, _ from: Double, _ to: Double, _ fromJunction: String?, _ toJunction: String?) -> HorizontalSegment {
            HorizontalSegment(id: id, from: p(from), to: p(to), width: 250_000, layer: top, netID: "n",
                              fromJunctionID: fromJunction, toJunctionID: toJunction)
        }
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/deletion-splice.hprj"), uuid: "b", name: "deletion splice",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: ["j1": p(10), "j2": p(20), "j3": p(30)], junctionNetIDs: ["j1": "n", "j2": "n", "j3": "n"],
            netDetails: ["n": HorizontalNetDetails(id: "n", name: "N")],
            tracks: [track("t1", 0, 10, nil, "j1"), track("t2", 10, 20, "j1", "j2"), track("t3", 20, 30, "j2", "j3")],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [HorizontalMarker(id: "v", position: p(30), size: 600_000, holeSize: 300_000, layer: nil,
                                    connectedLayers: [top, HorizontalBoardLayers.bottomCopper], netID: "n")],
            viaHoles: [HorizontalHole(id: HorizontalBoard.viaHoleID(ofVia: "v"), position: p(30), diameter: 300_000,
                                      plated: true, netID: "n")],
            packages: [
                HorizontalPlacement(id: "pa", position: p(0), angle: 0, mirrored: false, label: "A", componentID: "ca", fixed: true),
                HorizontalPlacement(id: "pb", position: p(40), angle: 0, mirrored: false, label: "B", componentID: "cb", fixed: true),
            ],
            packagePads: [pad("pa", "a1", at: p(0)), pad("pb", "b1", at: p(40))],
            packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["pa/a1": p(0), "pb/b1": p(40)]
        return HorizontalBoardConnectivity.recompute(board)
    }

    /// `board` less the tracks and vias named, as the canvas's delete
    /// leaves it, through the connectivity pass it commits with.
    private func deleting(_ ids: Set<String>, from board: HorizontalBoard) -> HorizontalBoard {
        var draft = board
        draft.tracks.removeAll { ids.contains($0.id) }
        draft.vias.removeAll { ids.contains($0.id) }
        draft.viaHoles.removeAll { ids.contains(HorizontalBoard.viaID(ofViaHole: $0.id) ?? "") }
        return HorizontalBoardConnectivity.recompute(draft)
    }

    private func owner(_ type: HorizontalObjectType, _ id: String) -> BoardDeletionSplice.Owner {
        .init(type: type, id: id)
    }

    func testTheCopperOfTheChainHasItsNet() {
        let board = board()
        XCTAssertEqual(board.tracks.map(\.netID), ["n", "n", "n"])
        XCTAssertEqual(board.vias.map(\.netID), ["n"])
    }

    /// The far end of the chain: t2 stays on a1's net, and the via t3 joined
    /// to it is on none now, so it is drawn again.
    func testATrackOffTheEndOfAChainIsTakenOut() throws {
        let board = board()
        let splice = try XCTUnwrap(BoardDeletionSplice(from: board, to: deleting(["t3"], from: board)))
        XCTAssertEqual(splice.removed, [owner(.track, "t3")], "j3 stays, the via stands on it")
        XCTAssertEqual(splice.redrawn, [owner(.via, "v")])
        XCTAssertEqual(splice.redrawnTracks, [], "t1 and t2 are as they were")
    }

    /// t2 joined t3 and the via to a1; without it they are on no net, so
    /// they draw orange and lose their labels, and are drawn again.
    func testCopperCutOffFromItsPadsIsDrawnAgain() throws {
        let board = board()
        let resolved = deleting(["t2"], from: board)
        XCTAssertEqual(resolved.tracks.first { $0.id == "t3" }?.netID, nil, "t3 reaches no pad now")
        let splice = try XCTUnwrap(BoardDeletionSplice(from: board, to: resolved))
        XCTAssertEqual(splice.removed, [owner(.track, "t2")])
        XCTAssertEqual(splice.redrawn, [owner(.track, "t3"), owner(.via, "v")])
        XCTAssertEqual(splice.redrawnTracks.map(\.id), ["t3"])
        XCTAssertEqual(splice.redrawnTracks.map(\.netID), [nil])
        XCTAssertEqual(splice.redrawnVias.map(\.id), ["v"])
        XCTAssertEqual(splice.redrawnViaHoles.map(\.id), ["v/hole"], "the drill draws with its via")

        let redrawn = splice.redrawnBoard(of: resolved)
        XCTAssertEqual(redrawn.tracks.map(\.id), ["t3"], "only what is drawn again")
        XCTAssertEqual(redrawn.vias.map(\.id), ["v"])
        XCTAssertEqual(redrawn.packages, [])
        XCTAssertEqual(redrawn.packagePads, [])
        XCTAssertEqual(redrawn.airwires, resolved.airwires, "and the rats' nest, whole")
        XCTAssertEqual(redrawn.packagePadPositions, resolved.packagePadPositions, "a track's label looks for the pads")
    }

    /// The via and its drill go together, and the junction the last track
    /// and the via held goes with them.
    func testAViaGoesWithItsDrillAndTheJunctionLetGo() throws {
        let board = board()
        let splice = try XCTUnwrap(BoardDeletionSplice(from: board, to: deleting(["t3", "v"], from: board)))
        XCTAssertEqual(splice.removed, [owner(.track, "t3"), owner(.via, "v"), owner(.junction, "j3")])
        XCTAssertEqual(splice.redrawn, [], "what is left keeps a1's net")
    }

    func testADrillWithoutItsViaHasNoSplice() {
        let board = board()
        var resolved = deleting(["t3"], from: board)
        resolved.viaHoles = []
        XCTAssertNil(BoardDeletionSplice(from: board, to: resolved))
    }

    /// A delete that took a package too has to be built: its pads, its
    /// outline and its texts are not copper the splice knows.
    func testADeleteThatTookMoreThanCopperHasNoSplice() {
        let board = board()
        var resolved = deleting(["t3"], from: board)
        resolved.packages.removeLast()
        resolved.packagePads.removeLast()
        XCTAssertNil(BoardDeletionSplice(from: board, to: resolved))
    }

    /// Copper left that changed other than in its net (the rules gave it a
    /// width) is not what the scene drew.
    func testCopperLeftThatChangedOtherwiseHasNoSplice() {
        let board = board()
        var resolved = deleting(["t3"], from: board)
        resolved.tracks[0].width = 400_000
        XCTAssertNil(BoardDeletionSplice(from: board, to: resolved))
        var moved = deleting(["t3"], from: board)
        moved.junctions["j1"] = p(11)
        XCTAssertNil(BoardDeletionSplice(from: board, to: moved), "a junction that moved")
        var added = deleting(["t3"], from: board)
        added.tracks.append(HorizontalSegment(id: "t9", from: p(50), to: p(60), width: 250_000, layer: top))
        XCTAssertNil(BoardDeletionSplice(from: board, to: added), "something new")
    }

    func testADeleteThatTookNothingHasNoSplice() {
        let board = board()
        XCTAssertNil(BoardDeletionSplice(from: board, to: board))
    }

    /// Every primitive an object drew goes, on whatever layer its ref
    /// names and however its id is written.
    func testOwnersMatchByTypeAndIdAlone() throws {
        let board = board()
        let splice = try XCTUnwrap(BoardDeletionSplice(from: board, to: deleting(["t2"], from: board)))
        XCTAssertTrue(splice.removes(HorizontalSelectableRef(id: "T2", type: .track, layer: top)))
        XCTAssertFalse(splice.removes(HorizontalSelectableRef(id: "t2", type: .boardLine)))
        XCTAssertFalse(splice.removes(HorizontalSelectableRef(id: "t3", type: .track)), "t3 stays")
        XCTAssertTrue(splice.replaces(HorizontalSelectableRef(id: "t3", type: .track, layer: top)), "drawn again")
        XCTAssertTrue(splice.replaces(HorizontalSelectableRef(id: "v", type: .via)))
        XCTAssertFalse(splice.replaces(HorizontalSelectableRef(id: "t1", type: .track)))
        XCTAssertFalse(splice.replaces(nil))
    }

    private func line(_ x: Double) -> HorizontalMetalLinePrimitive {
        HorizontalMetalLinePrimitive(from: HorizontalPoint(x: x, y: 0), to: HorizontalPoint(x: x + 1, y: 0),
                                     color: HorizontalMetalRGBA(red: 1, green: 1, blue: 1, alpha: 1), width: 1)
    }

    /// A text's strokes go or stay together, and the runs of the texts
    /// left keep pointing at their own strokes.
    func testABatchLosesWhatItsRemovedObjectsDrew() throws {
        let board = board()
        let splice = try XCTUnwrap(BoardDeletionSplice(from: board, to: deleting(["t2"], from: board)))
        let t1 = HorizontalSelectableRef(id: "t1", type: .track, layer: top)
        let t2 = HorizontalSelectableRef(id: "t2", type: .track, layer: top)
        var batch = BoardMetalElementBatch()
        batch.appendLines([line(0), line(1)], owner: t2, labelSize: 1)
        batch.textRuns.append(BoardMetalTextRun(textID: "t2-label", lineStart: 0, lineCount: 2))
        batch.appendLines([line(2), line(3), line(4)], owner: t1, labelSize: 1)
        batch.textRuns.append(BoardMetalTextRun(textID: "t1-label", lineStart: 2, lineCount: 3))
        batch.appendLine(line(5))
        let left = batch.removingOwners(where: splice.removes)
        XCTAssertEqual(left.lines, [line(2), line(3), line(4), line(5)])
        XCTAssertEqual(left.lineOwners, [t1, t1, t1, nil])
        XCTAssertEqual(left.lineLabelSizes, [1, 1, 1, 0])
        XCTAssertEqual(left.textRuns.map(\.textID), ["t1-label"])
        XCTAssertEqual(left.textRuns.map(\.lineStart), [0])

        let untouched = BoardMetalElementBatch().removingOwners(where: splice.removes)
        XCTAssertEqual(untouched.lines, [])
    }

    /// What went leaves the scene, what is drawn again is drawn from the
    /// addition, and the airwires are the addition's alone.
    func testASplicedSceneTakesTheRedrawnCopperAndTheNewRatsNest() throws {
        let board = board()
        let splice = try XCTUnwrap(BoardDeletionSplice(from: board, to: deleting(["t2"], from: board)))
        let t1 = HorizontalSelectableRef(id: "t1", type: .track, layer: top)
        let t2 = HorizontalSelectableRef(id: "t2", type: .track, layer: top)
        let t3 = HorizontalSelectableRef(id: "t3", type: .track, layer: top)
        let built = BoardMetalElementBuckets()
        built.alwaysOnLayered.appendLine(line(0), owner: t1)
        built.alwaysOnLayered.appendLine(line(1), owner: t2)
        built.alwaysOnLayered.appendLine(line(2), owner: t3)
        built.connectionLines.appendLine(line(10))
        built.airwires = [HorizontalSegment(id: "old", from: p(0), to: p(40), width: 0, layer: nil)]
        let addition = BoardMetalElementBuckets()
        addition.alwaysOnLayered.appendLine(line(20), owner: t3)
        addition.connectionLines.appendLine(line(30))
        addition.airwires = [HorizontalSegment(id: "new", from: p(20), to: p(40), width: 0, layer: nil)]

        let spliced = built.spliced(splice, adding: addition, replacing: [\.connectionLines, \.connectionLabels])
        XCTAssertEqual(spliced.alwaysOnLayered.lines, [line(0), line(20)], "t1 as it was, t3 drawn again, t2 gone")
        XCTAssertEqual(spliced.alwaysOnLayered.lineOwners, [t1, t3])
        XCTAssertEqual(spliced.connectionLines.lines, [line(30)])
        XCTAssertEqual(spliced.airwires.map(\.id), ["new"])
    }
}
