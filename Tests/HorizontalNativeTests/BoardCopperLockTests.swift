import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Horizon's Lock, Unlock and Unlock All on tracks and vias, as the model has
/// them (`BoardCopperLock`): the flag set on the copper named and no other,
/// what a lock holds still, the route tool's loop removal leaving locked
/// copper, and `locked` written as Horizon writes it and read back.
final class BoardCopperLockTests: XCTestCase {
    private let mm = 1_000_000
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    /// The template project, its planes off, with its copper replaced by a run of two tracks,
    /// j1–j2–j3 on the top, with a via on j2. `t1` and `v1` say nothing of
    /// `locked`, as a file Horizon didn't write may not; `t2` says false.
    private func fixture() throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-copper-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let boardURL = url.appendingPathComponent("board.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        // No planes, whose fill a via in it would join.
        json["planes"] = [String: Any]()
        json["polygons"] = [String: Any]()
        json["junctions"] = [
            "j1": ["position": [10 * mm, 10 * mm]],
            "j2": ["position": [15 * mm, 10 * mm]],
            "j3": ["position": [20 * mm, 10 * mm]],
        ]
        json["tracks"] = [
            "t1": ["from": ["junc": "j1"], "to": ["junc": "j2"], "layer": 0, "width": 250_000, "width_from_net_class": false],
            "t2": ["from": ["junc": "j2"], "to": ["junc": "j3"], "layer": 0, "width": 250_000, "width_from_net_class": false,
                   "locked": false],
        ]
        json["vias"] = ["v1": ["junction": "j2", "padstack": HorizontalProjectArchive.horizonPoolTentedCircularVia,
                               "parameter_set": ["via_diameter": 600_000, "hole_diameter": 300_000],
                               "from_rules": false, "source": "local"]]
        try JSONSerialization.data(withJSONObject: json).write(to: boardURL)
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
        return try XCTUnwrap(project.board)
    }

    private func entries(_ key: String) throws -> [String: [String: Any]] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json[key] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    private func track(_ id: String) -> HorizontalSelectableRef { HorizontalSelectableRef(id: id, type: .track) }
    private func via(_ id: String) -> HorizontalSelectableRef { HorizontalSelectableRef(id: id, type: .via) }

    func testLockAndUnlockChangeOnlyTheTracksAndViasNamed() throws {
        var board = try fixture()
        XCTAssertFalse(BoardCopperLock.hasLocked(board), "a file that says nothing of locked reads unlocked")
        let refs = [track("t1"), via("v1"), HorizontalSelectableRef(id: "j1", type: .junction)]
        XCTAssertTrue(BoardCopperLock.canSet(true, on: refs, in: board))
        XCTAssertFalse(BoardCopperLock.canSet(false, on: refs, in: board), "nothing to unlock yet")

        XCTAssertTrue(BoardCopperLock.setLocked(true, on: refs, in: &board))
        XCTAssertEqual(board.tracks.filter(\.locked).map(\.id), ["t1"])
        XCTAssertEqual(board.vias.filter(\.locked).map(\.id), ["v1"])
        XCTAssertFalse(BoardCopperLock.setLocked(true, on: refs, in: &board), "locking it again changes nothing")
        XCTAssertFalse(BoardCopperLock.canSet(true, on: refs, in: board))
        XCTAssertTrue(BoardCopperLock.isLocked(track("T1"), in: board), "ids match whatever their case")

        XCTAssertTrue(BoardCopperLock.setLocked(false, on: [via("v1")], in: &board))
        XCTAssertEqual(board.tracks.filter(\.locked).map(\.id), ["t1"], "unlocking the via leaves the track")
        XCTAssertTrue(board.vias.allSatisfy { !$0.locked })

        XCTAssertTrue(BoardCopperLock.setLocked(true, on: [track("t2"), via("v1")], in: &board))
        XCTAssertTrue(BoardCopperLock.unlockAll(in: &board))
        XCTAssertFalse(BoardCopperLock.hasLocked(board), "Unlock All frees every track and via")
        XCTAssertFalse(BoardCopperLock.unlockAll(in: &board))
    }

    func testALockHoldsTheCopperAndTheJunctionsAndViasAtItsEnds() throws {
        var board = try fixture()
        let all = [track("t1"), track("t2"), via("v1"),
                   HorizontalSelectableRef(id: "j1", type: .junction),
                   HorizontalSelectableRef(id: "j2", type: .junction),
                   HorizontalSelectableRef(id: "j3", type: .junction)]
        XCTAssertEqual(BoardCopperLock.removingHeld(all, in: board), all, "nothing is held with nothing locked")

        BoardCopperLock.setLocked(true, on: [track("t2")], in: &board)
        XCTAssertEqual(BoardCopperLock.removingHeld(all, in: board).map(\.id), ["t1", "j1"],
                       "the locked track, the junctions it ends on and the via on one of them stay")
        let pinned = Set(BoardCopperLock.pinnedEndPositions(board).values)
        XCTAssertTrue(pinned.isSuperset(of: [HorizontalPoint(x: Double(15 * mm), y: Double(10 * mm)),
                                             HorizontalPoint(x: Double(20 * mm), y: Double(10 * mm))]),
                      "a track moved off the locked one keeps its end there, as on a pad")

        BoardCopperLock.unlockAll(in: &board)
        BoardCopperLock.setLocked(true, on: [via("v1")], in: &board)
        XCTAssertEqual(BoardCopperLock.removingHeld(all, in: board).map(\.id), ["t1", "t2", "j1", "j3"],
                       "a locked via holds itself and its junction; the tracks on it may move off it")
    }

    /// A package carries the track ends on its pads, so a move of one with a
    /// locked track on a pad would stretch the track.
    func testALockedTrackOnAPadHoldsThePackageThroughAMoveAndNotADelete() throws {
        var board = try fixture()
        // A pad of one package under t2's far end, and one of another clear
        // of the copper.
        board.packagePadPositions["pkg-a/pad-1"] = HorizontalPoint(x: Double(20 * mm), y: Double(10 * mm))
        board.packagePadPositions["pkg-b/pad-1"] = HorizontalPoint(x: Double(40 * mm), y: Double(10 * mm))
        let a = HorizontalSelectableRef(id: "pkg-a", type: .boardPackage)
        let b = HorizontalSelectableRef(id: "pkg-b", type: .boardPackage)
        XCTAssertFalse(BoardCopperLock.holdsPackage("pkg-a", in: board), "an unlocked track holds nothing")

        BoardCopperLock.setLocked(true, on: [track("t2")], in: &board)
        XCTAssertTrue(BoardCopperLock.holdsPackage("PKG-A", in: board))
        XCTAssertFalse(BoardCopperLock.holdsPackage("pkg-b", in: board))
        XCTAssertEqual(BoardCopperLock.removingHeld([a, b, track("t1")], in: board), [b, track("t1")],
                       "the package under the locked track's end stays through a move")
        XCTAssertEqual(BoardCopperLock.removingHeld([a, b, track("t2")], in: board, keepingPackages: true), [a, b],
                       "a delete takes the package, whose tracks stay where they are, and leaves the locked track")

        BoardCopperLock.setLocked(false, on: [track("t2")], in: &board)
        BoardCopperLock.setLocked(true, on: [track("t1")], in: &board)
        XCTAssertFalse(BoardCopperLock.holdsPackage("pkg-a", in: board), "t1 ends on no pad")
    }

    /// Locked copper is drawn with a padlock (`BoardCopperLockMark`).
    func testLockedCopperCarriesAPadlockClearOfItsNetName() throws {
        var board = try fixture()
        XCTAssertTrue(board.tracks.allSatisfy { BoardCopperLockMark.marks(for: $0).isEmpty })
        XCTAssertTrue(board.vias.allSatisfy { BoardCopperLockMark.marks(for: $0).isEmpty })

        BoardCopperLock.setLocked(true, on: [track("t2"), via("v1")], in: &board)
        let t2 = try XCTUnwrap(board.tracks.first { $0.id == "t2" })
        let onTrack = BoardCopperLockMark.marks(for: t2)
        XCTAssertEqual(onTrack.count, 2, "one in from each end of a 5 mm track, the middle left to the net's name")
        for mark in onTrack {
            let box = HorizontalRect(points: mark.strokes.flatMap { $0 })
            XCTAssertEqual(box.center.y, Double(10 * mm), accuracy: 30_000, "on the track's centre line")
            XCTAssertLessThanOrEqual(box.maxY - box.minY, t2.width, "within the track's width")
            XCTAssertTrue(box.minX > Double(15 * mm) && box.maxX < Double(20 * mm), "between the track's ends")
            XCTAssertFalse(box.minX < Double(17_500_000) && box.maxX > Double(17_500_000), "clear of the middle")
        }

        var short = t2
        short.to = HorizontalPoint(x: t2.from.x + 600_000, y: t2.from.y)
        XCTAssertEqual(BoardCopperLockMark.marks(for: short).count, 1, "a track too short for two carries one")

        let v1 = try XCTUnwrap(board.vias.first { $0.id == "v1" })
        let onVia = try XCTUnwrap(BoardCopperLockMark.marks(for: v1).first)
        let box = HorizontalRect(points: onVia.strokes.flatMap { $0 })
        let hole = (v1.holeSize ?? v1.size / 2) / 2
        XCTAssertGreaterThanOrEqual(box.minY, v1.position.y + hole, "above the drill")
        XCTAssertLessThanOrEqual(box.maxY, v1.position.y + v1.size / 2, "inside the via's edge")
    }

    func testRouteLoopRemovalKeepsAChainWithLockedCopper() throws {
        // t2 on the bottom, so the via passes the chain from layer to layer.
        var board = try fixture()
        let bottom = HorizontalBoardLayers.bottomCopper
        board.tracks = board.tracks.map { track in
            var track = track
            if track.id == "t2" { track.layer = bottom }
            return track
        }
        let start = BoardTrackLoopEnd(point: HorizontalPoint(x: Double(10 * mm), y: Double(10 * mm)), layer: 0)
        let end = BoardTrackLoopEnd(point: HorizontalPoint(x: Double(20 * mm), y: Double(10 * mm)), layer: bottom)
        let free = BoardTrackLoops.redundantCopper(from: start, to: end, sparing: [], in: board)
        XCTAssertEqual(Set(free.trackIDs), ["t1", "t2"], "a route from j1 to j3 replaces the chain between them")
        XCTAssertEqual(free.viaIDs, ["v1"])

        BoardCopperLock.setLocked(true, on: [track("t2")], in: &board)
        XCTAssertTrue(BoardTrackLoops.redundantCopper(from: start, to: end, sparing: [], in: board).trackIDs.isEmpty,
                      "a chain with a locked track in it stays")
        BoardCopperLock.unlockAll(in: &board)
        BoardCopperLock.setLocked(true, on: [via("v1")], in: &board)
        XCTAssertTrue(BoardTrackLoops.redundantCopper(from: start, to: end, sparing: [], in: board).trackIDs.isEmpty,
                      "and so does one through a locked via")
    }

    func testLockedIsWrittenAsHorizonWritesItAndReadBack() throws {
        var board = try fixture()

        // Untouched, the file stays as it was: no `locked` where it had none.
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertNil(try entries("tracks")["t1"]?["locked"])
        XCTAssertNil(try entries("vias")["v1"]?["locked"])
        XCTAssertEqual(try entries("tracks")["t2"]?["locked"] as? Bool, false)

        BoardCopperLock.setLocked(true, on: [track("t1"), via("v1")], in: &board)
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual(try entries("tracks")["t1"]?["locked"] as? Bool, true, "Track::serialize's locked")
        XCTAssertEqual(try entries("vias")["v1"]?["locked"] as? Bool, true, "Via::serialize's locked")
        XCTAssertEqual(try entries("tracks")["t2"]?["locked"] as? Bool, false)
        let locked = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertEqual(locked.tracks.filter(\.locked).map(\.id), ["t1"])
        XCTAssertEqual(locked.vias.filter(\.locked).map(\.id), ["v1"])

        var unlocked = board
        BoardCopperLock.unlockAll(in: &unlocked)
        try HorizontalProjectJSONApplicator.apply(board: unlocked, in: project, to: &archive)
        XCTAssertEqual(try entries("tracks")["t1"]?["locked"] as? Bool, false, "unlocked, the file says so")
        XCTAssertEqual(try entries("vias")["v1"]?["locked"] as? Bool, false)
        let reread = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertFalse(BoardCopperLock.hasLocked(reread))
        XCTAssertEqual(reread.tracks.count, 2, "and the copper is all still there")
        XCTAssertEqual(reread.vias.count, 1)
    }

    func testTheInspectorOffersLockedOnCopperAndANetOnAViaThatCanTakeOne() throws {
        var board = try fixture()
        XCTAssertEqual(BoardCopperLockCommands.lockedProperty(track("t1"), locked: true)?.value, .bool(true))
        XCTAssertNil(BoardCopperLockCommands.lockedProperty(HorizontalSelectableRef(id: "l", type: .boardLine), locked: false))

        let v1 = try XCTUnwrap(board.vias.first)
        let options = [HorizontalSelectionPropertyOption(id: "n1", title: "GND")]
        let net = try XCTUnwrap(BoardCopperLockCommands.viaNetProperty(v1, in: board, options: { options }),
                                "a netless via whose copper reaches no pad can take a net")
        XCTAssertEqual(net.value, .choice(""))
        XCTAssertEqual(net.editor, .choice([HorizontalSelectionPropertyOption(id: "", title: "None")] + options))

        XCTAssertTrue(BoardCopperLockCommands.apply(.bool(true), propertyID: "locked", to: via("v1"), board: &board))
        XCTAssertTrue(board.vias[0].locked)
        XCTAssertTrue(BoardCopperLockCommands.apply(.choice(""), propertyID: "viaNet", to: via("v1"), board: &board))
        XCTAssertNil(board.vias[0].netSetID, "None takes no net off and gives none")
        XCTAssertFalse(BoardCopperLockCommands.apply(.bool(true), propertyID: "plated", to: via("v1"), board: &board),
                       "other rows are the inspector's own")

        XCTAssertEqual(menuTitle(BoardCopperLockCommands.menuEntry(for: via("v1"), in: board)), "Unlock")
        XCTAssertEqual(menuTitle(BoardCopperLockCommands.menuEntry(for: track("t1"), in: board)), "Lock")
        XCTAssertNil(BoardCopperLockCommands.menuEntry(for: HorizontalSelectableRef(id: "j1", type: .junction), in: board))
    }

    private func menuTitle(_ entry: HorizontalTargetItemMenuEntry?) -> String? {
        if case .command(let title, _)? = entry { return title }
        return nil
    }
}
