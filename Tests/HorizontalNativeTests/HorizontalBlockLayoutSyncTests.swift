import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// An edit of one instance's parts or copper made the same in the instances
/// laid out like it, through the motion between them, and written to the
/// board file as Horizon writes it.
final class HorizontalBlockLayoutSyncTests: XCTestCase {
    private var fixture: BlockLayoutFixture!

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private let mm = 1_000_000.0
    private let bend = "a0000000-0000-4000-8000-000000000001"
    private let firstLeg = "b0000000-0000-4000-8000-000000000001"
    private let secondLeg = "b0000000-0000-4000-8000-000000000002"
    private let via = "c0000000-0000-4000-8000-000000000001"

    // MARK: - Helpers

    private var instances: HorizontalBoardBlockInstances {
        get throws { try XCTUnwrap(fixture.project.flattenedBlock).boardInstances }
    }

    private var poolURL: URL? {
        fixture.project.poolDirectory.map { fixture.project.baseURL.appendingPathComponent($0) }
    }

    /// The edit `edit` makes, then what the sync makes of it, on the board as
    /// the fixture has it now; the result written and loaded again.
    @discardableResult
    private func sync(_ kind: HorizontalBlockLayoutSync.Intent.Kind = .move, write: Bool = true,
                      _ edit: (inout HorizontalBoard) throws -> Void) throws -> (board: HorizontalBoard, changes: HorizontalBlockLayoutSync.ChangeSet?) {
        let baseline = try fixture.board
        var edited = baseline
        try edit(&edited)
        let changes = HorizontalBlockLayoutSync.propagate(baseline: baseline, edited: edited, instances: try instances, intent: .init(kind))
        var result = edited
        if let changes {
            _ = HorizontalBlockLayoutSync.apply(changes, to: &result, poolURL: poolURL)
        }
        if write {
            try fixture.write(HorizontalBoardConnectivity.recompute(result))
        }
        return (result, changes)
    }

    private func move(_ instance: Int, _ refdes: String, by dx: Double, _ dy: Double, in board: inout HorizontalBoard) throws {
        let package = try XCTUnwrap(board.packages.first { $0.componentID?.lowercased() == fixture.flat(fixture.instances[instance], refdes) })
        var placement = HorizontalBoard.placementTransform(of: package)
        placement.shift = HorizontalPoint(x: placement.shift.x + dx * mm, y: placement.shift.y + dy * mm)
        board.replacePackages([package.id: placement])
    }

    private func position(_ instance: Int, _ refdes: String) throws -> HorizontalPoint {
        try fixture.package(of: fixture.flat(fixture.instances[instance], refdes)).position
    }

    private func assertNear(_ point: HorizontalPoint, _ x: Double, _ y: Double, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.x, x * mm, accuracy: 2, message, file: file, line: line)
        XCTAssertEqual(point.y, y * mm, accuracy: 2, message, file: file, line: line)
    }

    /// I1's R1 pin 2 to R2 pin 1 over a bend 2 mm up, with a via on it.
    private func addMidRoute(to board: inout HorizontalBoard, instance: Int = 0) throws {
        let r1 = try XCTUnwrap(board.packages.first { $0.componentID?.lowercased() == fixture.flat(fixture.instances[instance], "R1") })
        let r2 = try XCTUnwrap(board.packages.first { $0.componentID?.lowercased() == fixture.flat(fixture.instances[instance], "R2") })
        let pin2 = try XCTUnwrap(board.packagePadPositions["\(r1.id)/\(fixture.padIDs[1])"])
        let pin1 = try XCTUnwrap(board.packagePadPositions["\(r2.id)/\(fixture.padIDs[0])"])
        let point = HorizontalPoint(x: (pin2.x + pin1.x) / 2, y: pin2.y + 2 * mm).rounded
        board.junctions[bend] = point
        board.tracks.append(HorizontalSegment(id: firstLeg, from: pin2, to: point, width: 200_000, layer: 0, toJunctionID: bend))
        board.tracks.append(HorizontalSegment(id: secondLeg, from: point, to: pin1, width: 200_000, layer: 0, fromJunctionID: bend))
        board.vias.append(HorizontalMarker(id: via, position: point, size: 500_000, holeSize: 250_000, layer: nil,
                                           connectedLayers: [0, -100],
                                           padstackID: HorizontalProjectArchive.defaultViaPadstack(poolDefaultVia: nil)))
    }

    private func tracks(of instance: Int, in board: HorizontalBoard) throws -> [HorizontalSegment] {
        let match = HorizontalBlockLayoutMatch(board: board, instances: try instances)
        let owned = match.owned(fixture.path(instance))
        return board.tracks.filter { owned.tracks.contains($0.id.lowercased()) }
    }

    // MARK: - Parts

    func testMovingAPartMovesTheSamePartOfEveryInstanceLaidOutLikeIt() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        try fixture.place(fixture.instances[1], x: 30, y: 20, angle: 90)
        let (_, changes) = try sync { try move(0, "R2", by: 0, 2, in: &$0) }
        XCTAssertEqual(changes?.report.changed, ["I2", "I3"])
        assertNear(try position(0, "R2"), 5, 2, "the edit itself")
        assertNear(try position(1, "R2"), 28, 25, "turned with I2: 2 mm up is 2 mm left")
        assertNear(try position(2, "R2"), 45, 2)
        XCTAssertEqual(try fixture.package(of: fixture.flat(fixture.instances[1], "R2")).angle, 16_384)

        // And from I2 back to the others.
        try sync { try move(1, "R3", by: 1, 0, in: &$0) }
        assertNear(try position(0, "R3"), 10, -1, "1 mm right in I2 is 1 mm down in I1")
        assertNear(try position(2, "R3"), 50, -1)
    }

    func testAnInstanceMovedAsAWholeMovesNothingElse() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let (_, changes) = try sync {
            for part in ["R1", "R2", "R3"] { try move(0, part, by: 3, 4, in: &$0) }
        }
        XCTAssertNil(changes)
        assertNear(try position(1, "R1"), 20, 0)
    }

    func testMovingSomeOfAnInstancesPartsIsAnEditOfThem() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        try sync {
            try move(0, "R2", by: 0, 1, in: &$0)
            try move(0, "R3", by: 0, 1, in: &$0)
        }
        assertNear(try position(1, "R1"), 20, 0, "the part left alone stays")
        assertNear(try position(1, "R2"), 25, 1)
        assertNear(try position(1, "R3"), 30, 1)
    }

    func testAFixedPartIsLeftAndSaidSo() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        var board = try fixture.board
        let fixedID = try fixture.packageID(fixture.instances[1], "R2")
        let index = try XCTUnwrap(board.packages.firstIndex { $0.id == fixedID })
        board.packages[index].fixed = true
        try fixture.write(board)
        let (_, changes) = try sync { try move(0, "R2", by: 0, 2, in: &$0) }
        assertNear(try position(1, "R2"), 25, 0)
        assertNear(try position(2, "R2"), 45, 2)
        XCTAssertEqual(changes?.report.skipped, ["R2 in I2 is fixed"])
    }

    func testTwoInstancesChangedDifferentlyKeepTheirOwnAndSaySo() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        let (_, changes) = try sync {
            try move(0, "R2", by: 0, 2, in: &$0)
            try move(1, "R2", by: 0, -2, in: &$0)
        }
        assertNear(try position(0, "R2"), 5, 2)
        assertNear(try position(1, "R2"), 25, -2)
        assertNear(try position(2, "R2"), 45, 2, "the first instance's edit reaches the third")
        XCTAssertFalse(changes?.report.conflicts.isEmpty ?? true)
    }

    func testAPartPlacedInOneInstanceIsPlacedInTheOthers() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        var json = try fixture.boardJSON()
        let r3 = Set(fixture.instances.map { fixture.flat($0, "R3") })
        json["packages"] = json.dictionaryMap("packages").filter { !r3.contains($0.value.string("component")?.lowercased() ?? "") }
        try fixture.putBoard(json)
        let poolURL = try XCTUnwrap(poolURL)
        try sync(.placePackage) { board in
            let object = try XCTUnwrap(board.unplacedObjects.first { $0.componentID?.lowercased() == fixture.flat(fixture.instances[0], "R3") })
            let draft = try XCTUnwrap(HorizontalBoard.placingPackage(for: object, in: board, at: HorizontalPoint(x: 10 * mm, y: 3 * mm), poolURL: poolURL))
            board = draft.board
        }
        assertNear(try position(1, "R3"), 30, 3)
        assertNear(try position(2, "R3"), 50, 3)
        XCTAssertEqual(try fixture.board.packages.count, 9)
    }

    // MARK: - Copper

    func testCopperAddedInOneInstanceIsAddedInTheOthers() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        try fixture.place(fixture.instances[1], x: 30, y: 20, angle: 90)
        try fixture.place(fixture.instances[2], x: 70, y: 0, bottom: true)
        let (_, changes) = try sync(.drawTrack) { try addMidRoute(to: &$0) }
        XCTAssertEqual(changes?.report.changed, ["I2", "I3"])

        let board = try fixture.board
        let json = try fixture.boardJSON()
        XCTAssertEqual(json.dictionaryMap("tracks").count, 6, "two in each, in the file")
        XCTAssertEqual(json.dictionaryMap("vias").count, 3)
        for index in [1, 2] {
            let copies = try tracks(of: index, in: board)
            XCTAssertEqual(copies.count, 2, "I\(index + 1)")
            XCTAssertEqual(Set(copies.map(\.layer)), [index == 2 ? -100 : 0], "I\(index + 1)'s side")
            // The legs end on the instance's own pads.
            let pads = Set(try ["R1", "R2"].map { try fixture.packageID(fixture.instances[index], $0).lowercased() })
            for copy in copies {
                let entry = try XCTUnwrap(json.dictionaryMap("tracks")[copy.id.lowercased()] ?? json.dictionaryMap("tracks")[copy.id])
                let padEnds = [entry.dictionary("from")?.string("pad"), entry.dictionary("to")?.string("pad")].compactMap { $0 }
                XCTAssertEqual(padEnds.count, 1, "one end on a pad")
                XCTAssertTrue(padEnds.allSatisfy { pads.contains(String($0.lowercased().split(separator: "/").first!)) })
            }
        }
        // The bend where the motion puts it.
        let match = HorizontalBlockLayoutMatch(board: board, instances: try instances)
        let pair = try XCTUnwrap(match.pair(from: fixture.path(0), to: fixture.path(1)))
        let bendPoint = try XCTUnwrap(board.junctions[bend])
        let landing = pair.transform.applying(to: bendPoint)
        XCTAssertTrue(board.junctions.values.contains { HorizontalBlockLayoutMatch.distance($0, landing) <= 2 })
        // Synced now: an edit again reaches them, and a second pass finds nothing to do.
        XCTAssertEqual(match.copper(from: fixture.path(0), to: fixture.path(1)).tracks.count, 2)
        XCTAssertEqual(match.copper(from: fixture.path(0), to: fixture.path(2)).tracks.count, 2)
        let again = HorizontalBlockLayoutSync.propagate(baseline: board, edited: board, instances: try instances, intent: .init(.move))
        XCTAssertNil(again)
    }

    func testCopperMovedOrDeletedInOneInstanceIsInTheOthers() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        try sync(.drawTrack) { try addMidRoute(to: &$0) }
        // The bend 1 mm further up in I2.
        let base = try fixture.board
        let match = HorizontalBlockLayoutMatch(board: base, instances: try instances)
        let secondBend = try XCTUnwrap(match.copper(from: fixture.path(0), to: fixture.path(1)).junctions[bend])
        try sync { board in
            let key = try XCTUnwrap(board.junctions.keys.first { $0.lowercased() == secondBend })
            let point = try XCTUnwrap(board.junctions[key])
            let moved = HorizontalPoint(x: point.x, y: point.y + mm)
            board.junctions[key] = moved
            for index in board.tracks.indices {
                if board.tracks[index].fromJunctionID?.lowercased() == secondBend { board.tracks[index].from = moved }
                if board.tracks[index].toJunctionID?.lowercased() == secondBend { board.tracks[index].to = moved }
            }
            for index in board.vias.indices where board.vias[index].position == point {
                board.vias[index].position = moved
            }
        }
        let moved = try fixture.board
        XCTAssertEqual(try XCTUnwrap(moved.junctions[bend]).y, 3 * mm, accuracy: 2, "I1's bend follows I2's")
        // Delete I1's second leg.
        try sync(.delete) { board in board.tracks.removeAll { $0.id == secondLeg } }
        let deleted = try fixture.board
        XCTAssertEqual(deleted.tracks.count, 3, "one leg left in each")
        XCTAssertEqual(try fixture.boardJSON().dictionaryMap("tracks").count, 3)
    }

    func testAPinnedViaIsPinnedToTheOtherInstancesNet() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let mid1 = try XCTUnwrap(try fixture.board.netDetails.first { $0.value.name == "I1/MID" }?.key)
        let mid2 = try XCTUnwrap(try fixture.board.netDetails.first { $0.value.name == "I2/MID" }?.key)
        let (_, changes) = try sync(.drawTrack) { board in
            try addMidRoute(to: &board)
            let index = try XCTUnwrap(board.vias.firstIndex { $0.id == via })
            board.vias[index].netSetID = mid1
        }
        let copy = try XCTUnwrap(changes?.vias.values.first)
        XCTAssertEqual(copy.netSetID, mid2)
        let json = try fixture.boardJSON()
        XCTAssertEqual(json.dictionaryMap("vias")[copy.id]?.string("net_set"), mid2)
    }

    func testTheSameEditInTwoInstancesIsNotCopiedTwice() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        // The route drawn in both at once, as an agent drawing each would.
        let (_, changes) = try sync(.drawTrack) { board in
            try addMidRoute(to: &board)
            let first = board
            var second = board
            try addMidRoute(to: &second, instance: 1)
            // Its own ids, the ones `addMidRoute` gives being I1's.
            func renamed(_ id: String) -> String { "d" + id.dropFirst() }
            for track in second.tracks where !first.tracks.contains(where: { $0.id == track.id && $0.from == track.from }) {
                var copy = track
                copy.id = renamed(track.id)
                copy.fromJunctionID = track.fromJunctionID.map(renamed)
                copy.toJunctionID = track.toJunctionID.map(renamed)
                board.tracks.append(copy)
            }
            let point = try XCTUnwrap(second.junctions[bend])
            board.junctions[renamed(bend)] = point
            var copyVia = try XCTUnwrap(first.vias.first { $0.id == self.via })
            copyVia.id = renamed(copyVia.id)
            copyVia.position = point
            board.vias.append(copyVia)
        }
        XCTAssertEqual(try fixture.boardJSON().dictionaryMap("tracks").count, 4)
        XCTAssertEqual(try fixture.boardJSON().dictionaryMap("vias").count, 2)
        XCTAssertTrue(changes?.tracks.isEmpty ?? true)
    }

    func testANewlyCopiedTrackKeepsIdsADryRunAndItsCommitAgreeOn() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let first = try sync(.drawTrack, write: false) { try addMidRoute(to: &$0) }
        let second = try sync(.drawTrack, write: false) { try addMidRoute(to: &$0) }
        XCTAssertEqual(first.changes, second.changes)
        XCTAssertEqual(Set(first.changes?.tracks.keys ?? [:].keys),
                       [HorizontalBlockLayoutSync.copyID(of: firstLeg, in: fixture.path(1)), HorizontalBlockLayoutSync.copyID(of: secondLeg, in: fixture.path(1))])
    }

    func testCopperCopiedAtAnAngleThatIsntCardinalLandsOnItsPads() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        try fixture.place(fixture.instances[1], x: 30, y: 20, angle: 30)
        try fixture.place(fixture.instances[2], x: 60, y: 20, angle: 45)
        try sync(.drawTrack) { try addMidRoute(to: &$0) }
        let json = try fixture.boardJSON()
        XCTAssertEqual(json.dictionaryMap("tracks").count, 6, "none dropped for an end a fraction off its pad")
        for (_, track) in json.dictionaryMap("tracks") {
            for end in ["from", "to"] {
                let item = try XCTUnwrap(track.dictionary(end))
                XCTAssertTrue(item.string("pad") != nil || item.string("junc") != nil)
            }
        }
        for (_, junction) in json.dictionaryMap("junctions") {
            let position = try XCTUnwrap(junction["position"] as? [Any])
            XCTAssertTrue(position.allSatisfy { $0 is Int || ($0 as? NSNumber).map { CFNumberIsFloatType($0) == false } ?? false }, "whole nanometres")
        }
    }

    func testAnArcCopiedToTheBottomRunsTheOtherWay() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        try fixture.place(fixture.instances[1], x: 40, y: 0, bottom: true)
        let (_, changes) = try sync(.drawTrack) { board in
            try addMidRoute(to: &board)
            let index = try XCTUnwrap(board.tracks.firstIndex { $0.id == firstLeg })
            let track = board.tracks[index]
            board.tracks[index].center = HorizontalPoint(x: track.to.x, y: track.from.y)
        }
        let copy = try XCTUnwrap(changes?.tracks[HorizontalBlockLayoutSync.copyID(of: firstLeg, in: fixture.path(1))])
        guard case .junction = copy.from else {
            return XCTFail("mirrored, the copy runs from the bend to the pad: \(copy.from)")
        }
        guard case .pad = copy.to else {
            return XCTFail("\(copy.to)")
        }
        XCTAssertNotNil(copy.segment.center)
        let json = try fixture.boardJSON()
        XCTAssertNotNil(json.dictionaryMap("tracks")[copy.segment.id]?["center"])
        XCTAssertEqual(json.dictionaryMap("tracks")[copy.segment.id]?.int("layer"), -100)
    }

    func testAPartTakenOffTheBoardIsTakenOffInTheOthers() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        try sync(.delete) { board in
            board.removePackages([try fixture.packageID(fixture.instances[0], "R3")])
        }
        let components = Set(try fixture.board.packages.compactMap { $0.componentID?.lowercased() })
        XCTAssertFalse(fixture.instances.contains { components.contains(fixture.flat($0, "R3")) })
        XCTAssertEqual(components.count, 6)
    }

    func testALockedTrackIsLeftAndSaidSo() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        try sync(.drawTrack) { try addMidRoute(to: &$0) }
        var json = try fixture.boardJSON()
        var tracks = json.dictionaryMap("tracks")
        let copy = HorizontalBlockLayoutSync.copyID(of: secondLeg, in: fixture.path(1))
        tracks[copy]?["locked"] = true
        json["tracks"] = tracks
        try fixture.putBoard(json)
        let (_, changes) = try sync(.delete) { board in board.tracks.removeAll { $0.id == secondLeg } }
        XCTAssertTrue(try fixture.board.tracks.contains { $0.id.lowercased() == copy })
        XCTAssertEqual(changes?.report.skipped, ["a locked track in I2"])
    }
}

/// Copy Layout to Other Instances: the other instances laid out as one is,
/// where they are, their own copper given way to its.
final class HorizontalBlockLayoutCopyTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private let mm = 1_000_000.0

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private var instances: HorizontalBoardBlockInstances {
        get throws { try XCTUnwrap(fixture.project.flattenedBlock).boardInstances }
    }

    func testCopyingALayoutLaysTheOthersOutAsItIs() throws {
        fixture = try BlockLayoutFixture(instances: 3)
        let (i1, i2, i3) = (fixture.instances[0], fixture.instances[1], fixture.instances[2])
        // I1: R2 and R3 a row up, joined by a track. I2: its own stub, and a
        // track from its R3 to I1's R1, which is neither's. I3: unplaced.
        try fixture.apply([
            ["op": "place_component", "component": fixture.flat(i1, "R2"), "x_mm": 5, "y_mm": 4],
            ["op": "place_component", "component": fixture.flat(i1, "R3"), "x_mm": 10, "y_mm": 4],
        ])
        var json = try fixture.boardJSON()
        let third = Set(["R1", "R2", "R3"].map { fixture.flat(i3, $0) })
        json["packages"] = json.dictionaryMap("packages").filter { !third.contains($0.value.string("component")?.lowercased() ?? "") }
        try fixture.putBoard(json)
        try fixture.addCopper(
            junctions: ["a0000000-0000-4000-8000-000000000009": HorizontalPoint(x: 23 * mm, y: -2 * mm)],
            tracks: [
                "b0000000-0000-4000-8000-000000000001": (try fixture.padEnd(i1, "R2", 2), try fixture.padEnd(i1, "R3", 1), 0),
                "b0000000-0000-4000-8000-000000000009": (try fixture.padEnd(i2, "R2", 1), fixture.junctionEnd("a0000000-0000-4000-8000-000000000009"), 0),
                "b0000000-0000-4000-8000-000000000008": (try fixture.padEnd(i2, "R3", 2), try fixture.padEnd(i1, "R1", 1), 0),
            ]
        )
        let board = try fixture.board
        let changes = HorizontalBlockLayoutSync.copyLayout(from: fixture.path(0), to: [fixture.path(1), fixture.path(2)], board: board, instances: try instances)
        XCTAssertEqual(changes.report.changed, ["I2", "I3"])
        var copied = board
        let poolURL = fixture.project.poolDirectory.map { fixture.project.baseURL.appendingPathComponent($0) }
        _ = HorizontalBlockLayoutSync.apply(changes, to: &copied, poolURL: poolURL)
        try fixture.write(HorizontalBoardConnectivity.recompute(copied))

        let match = try fixture.match()
        XCTAssertEqual(match.pair(from: fixture.path(0), to: fixture.path(1))?.related, true)
        XCTAssertEqual(match.pair(from: fixture.path(0), to: fixture.path(1))?.differs, [])
        XCTAssertEqual(match.pair(from: fixture.path(0), to: fixture.path(2))?.related, true, "I3 placed, beside I1")
        // Two of I2's three parts were laid out as I1's already: they stay,
        // and R1 goes where that motion puts I1's.
        XCTAssertEqual(try fixture.package(of: fixture.flat(i2, "R2")).position, HorizontalPoint(x: 25 * mm, y: 0))
        XCTAssertEqual(try fixture.package(of: fixture.flat(i2, "R1")).position, HorizontalPoint(x: 20 * mm, y: -4 * mm))
        let tracks = try fixture.boardJSON().dictionaryMap("tracks")
        XCTAssertNil(tracks["b0000000-0000-4000-8000-000000000009"], "I2's own stub gave way")
        XCTAssertNotNil(tracks["b0000000-0000-4000-8000-000000000008"], "copper that isn't I2's stays")
        XCTAssertEqual(match.copper(from: fixture.path(0), to: fixture.path(1)).tracks.count, 1)
        XCTAssertEqual(match.copper(from: fixture.path(0), to: fixture.path(2)).tracks.count, 1)
    }
}

/// What the sync does to texts smashed out of packages, and through blocks
/// within blocks.
final class HorizontalBlockLayoutSyncTextAndNestingTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private let mm = 1_000_000.0

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private var instances: HorizontalBoardBlockInstances {
        get throws { try XCTUnwrap(fixture.project.flattenedBlock).boardInstances }
    }

    private func sync(_ edit: (inout HorizontalBoard) throws -> Void) throws -> HorizontalBlockLayoutSync.ChangeSet? {
        let baseline = try fixture.board
        var edited = baseline
        try edit(&edited)
        let changes = HorizontalBlockLayoutSync.propagate(baseline: baseline, edited: edited, instances: try instances, intent: .init(.move))
        if let changes {
            _ = HorizontalBlockLayoutSync.apply(changes, to: &edited, poolURL: nil)
        }
        try fixture.write(HorizontalBoardConnectivity.recompute(edited))
        return changes
    }

    private func smashedText(_ instance: String, _ refdes: String) throws -> HorizontalText {
        let package = try fixture.package(of: fixture.flat(instance, refdes))
        return try XCTUnwrap(HorizontalBlockLayoutSync.smashedTexts(of: package, on: try fixture.board).first)
    }

    func testASmashedTextMovedInOneInstanceMovesInTheOther() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let (i1, i2) = (fixture.instances[0], fixture.instances[1])
        // Both R2s smashed, as Horizon writes a smashed package: its refdes a
        // board text of its own, from_smash, which the package names.
        var json = try fixture.boardJSON()
        var packages = json.dictionaryMap("packages")
        var texts = json.dictionaryMap("texts")
        for (index, instance) in [i1, i2].enumerated() {
            let id = try fixture.packageID(instance, "R2")
            let package = try fixture.package(of: fixture.flat(instance, "R2"))
            let text = "e000000\(index)-0000-4000-8000-000000000001"
            texts[text] = HorizontalSmash.text(
                from: ["text": "$RD", "size": 1_000_000, "width": 150_000],
                placement: HorizontalSmash.storedPlacement(drawing: HorizontalPlacementTransform(
                    shift: HorizontalPoint(x: package.position.x + 300_000, y: package.position.y + mm), angle: 0, mirrored: false)),
                layer: HorizontalBoardLayers.topSilkscreen)
            var entry = try XCTUnwrap(packages[id])
            entry["smashed"] = true
            entry["texts"] = [text]
            packages[id] = entry
        }
        json["packages"] = packages
        json["texts"] = texts
        try fixture.putBoard(json)
        let before = try smashedText(i1, "R2")
        let other = try smashedText(i2, "R2")
        XCTAssertNotEqual(before.text, "", "the refdes, smashed")
        let changes = try sync { board in
            let index = try XCTUnwrap(board.packageTexts.firstIndex { $0.id == before.id })
            board.packageTexts[index].position = HorizontalPoint(x: before.position.x + mm, y: before.position.y + mm / 2)
        }
        XCTAssertEqual(changes?.texts.count, 1)
        let after = try smashedText(i2, "R2")
        XCTAssertEqual(after.position.x, other.position.x + mm, accuracy: 2)
        XCTAssertEqual(after.position.y, other.position.y + mm / 2, accuracy: 2)
        XCTAssertEqual(after.text, other.text, "its own refdes")
    }

    func testAnEditInsideANestedInstanceReachesTheOthersOnce() throws {
        fixture = try BlockLayoutFixture(instances: 2, nested: true)
        let match = try fixture.match()
        let nested = fixture.path(0) + "/" + fixture.subInstance.lowercased()
        XCTAssertEqual(match.instances.instances[nested]?.name, "I1/S1")
        let changes = try sync { board in
            let id = try XCTUnwrap(board.packages.first { $0.componentID?.lowercased() == fixture.nestedFlat(fixture.instances[0]) }?.id)
            let package = try XCTUnwrap(board.packages.first { $0.id == id })
            var placement = HorizontalBoard.placementTransform(of: package)
            placement.shift = HorizontalPoint(x: placement.shift.x + mm, y: placement.shift.y)
            board.replacePackages([id: placement])
        }
        XCTAssertEqual(changes?.report.conflicts, [], "through Sub and through Channel the same")
        XCTAssertEqual(try fixture.package(of: fixture.nestedFlat(fixture.instances[1])).position, HorizontalPoint(x: 21 * mm, y: 5 * mm))
    }
}
