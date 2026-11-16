#if os(macOS)
import AppKit
#endif
import XCTest
@testable import HorizontalNative

extension ManyPackageBoard {
    static let quarterTurn = 16_384

    /// `plain`, a board of `columns` parts a row, with more for a part to
    /// carry or to leave: on one part in five a drilled hole with a track on
    /// it, on one in seven a junction on its first pad and on one in eleven
    /// another, one part in thirteen fixed, and on one in three a track of
    /// another net ending on a pad, which stays.
    static func withMoreOnThePads(_ plain: HorizontalBoard, columns: Int) -> HorizontalBoard {
        var board = plain
        for index in board.packages.indices {
            let id = board.packages[index].id
            let at = origin(index, columns: columns)
            if index % 5 == 0 {
                let hole = HorizontalPoint(x: at.x + 100_000, y: at.y - 1_300_000)
                let net = String(format: "99999999-0000-4000-8000-%012d", index)
                board.packageHoles.append(HorizontalHole(id: "\(id)/hole/1", position: hole, diameter: 400_000, plated: true, netID: net))
                board.tracks.append(HorizontalSegment(
                    id: String(format: "77777777-0000-4000-8000-%012d", index), from: hole,
                    to: HorizontalPoint(x: hole.x + 300_000, y: hole.y - 500_000), width: 200_000, layer: top, netID: net
                ))
            }
            let firstPad = padCentre(index, pair: 0, side: -1, columns: columns)
            if index % 7 == 0 {
                board.junctions[String(format: "66666666-0000-4000-8000-%012d", index)] = firstPad
            }
            if index % 11 == 0 {
                board.junctions[String(format: "55555555-0000-4000-8000-%012d", index)] = firstPad
            }
            if index % 13 == 5 {
                board.packages[index].fixed = true
            }
            if index % 3 == 1 {
                let pad = padCentre(index, pair: 0, side: 1, columns: columns)
                board.tracks.append(HorizontalSegment(
                    id: String(format: "88888888-0000-4000-8000-%012d", index), from: pad,
                    to: HorizontalPoint(x: pad.x + 200_000, y: pad.y - 900_000), width: 200_000, layer: top, netID: "another-net"
                ))
            }
        }
        return board
    }

    /// The names of the pads the two tracks of route `serial` end on: the
    /// first track's start and the second's end.
    static func routedPads(_ serial: Int, padPairs: Int) -> (from: String, to: String) {
        let (index, pair) = (serial / padPairs, serial % padPairs)
        return ("\(packageID(index))/\(2 * pair + 2)", "\(packageID(index + 1))/\(2 * pair + 1)")
    }
}

private func assertNear(
    _ lhs: [HorizontalPoint], _ rhs: [HorizontalPoint], _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(lhs.count, rhs.count, message, file: file, line: line)
    for (index, (a, b)) in zip(lhs, rhs).enumerated() where abs(a.x - b.x) > 0.001 || abs(a.y - b.y) > 0.001 {
        XCTFail("point \(index) is at \(a), not \(b) \(message)", file: file, line: line)
        return
    }
}

/// Many packages turned, mirrored, lined up or set in the inspector change
/// place in one pass over the board (`BoardPackageMoves`), and land where
/// each would taken on its own, the track ends and junctions on their pads
/// with them. A turn or mirror used to read every track and junction again
/// for each pad of each package, and lining parts up for each package.
final class BoardManyPackageTurnTests: XCTestCase {
    private let quarter = ManyPackageBoard.quarterTurn
    /// A pivot off every axis the grid of parts is symmetric about, so no
    /// pad turns or mirrors onto where another stood.
    private let pivot = HorizontalPoint(x: 12_345_678, y: 7_654_321)

    private func assertSameGeometry(_ lhs: HorizontalBoard, _ rhs: HorizontalBoard, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.packages, rhs.packages, file: file, line: line)
        XCTAssertEqual(lhs.packagePads, rhs.packagePads, file: file, line: line)
        XCTAssertEqual(lhs.packagePadPositions, rhs.packagePadPositions, file: file, line: line)
        XCTAssertEqual(lhs.packageHoles, rhs.packageHoles, file: file, line: line)
        XCTAssertEqual(lhs.packageLines, rhs.packageLines, file: file, line: line)
        XCTAssertEqual(lhs.packageTexts, rhs.packageTexts, file: file, line: line)
        XCTAssertEqual(lhs.tracks, rhs.tracks, file: file, line: line)
        XCTAssertEqual(lhs.junctions, rhs.junctions, file: file, line: line)
        XCTAssertEqual(lhs.junctionNetIDs, rhs.junctionNetIDs, file: file, line: line)
        XCTAssertEqual(lhs.vias, rhs.vias, file: file, line: line)
    }

    /// The track ends of `board` after a change that takes each point on a
    /// pad to `moved` of it, and leaves the rest.
    private func ends(of board: HorizontalBoard, carried moved: (HorizontalPoint) -> HorizontalPoint) -> (from: [HorizontalPoint], to: [HorizontalPoint]) {
        let onPad = Set(board.packagePadPositions.values.map(HorizontalCanvasModeSupport.pointKey))
        func end(_ point: HorizontalPoint) -> HorizontalPoint {
            onPad.contains(HorizontalCanvasModeSupport.pointKey(point)) ? moved(point) : point
        }
        return (board.tracks.map { end($0.from) }, board.tracks.map { end($0.to) })
    }

    func testPackagesTurnedTogetherTakeTheirPadsAndTheTrackEndsOnThem() {
        let board = ManyPackageBoard.board(packages: 60, columns: 8, padPairs: 2)
        var turned = board
        let passes = BoardPackageMoves.passes
        BoardPackageMoves.apply(board.packages.map { ($0.id, .turn(about: pivot, by: quarter)) }, to: &turned)

        XCTAssertEqual(BoardPackageMoves.passes - passes, 1, "the tracks and junctions are read once for all sixty")
        // A quarter turn, worked out here without the sine.
        func turn(_ point: HorizontalPoint) -> HorizontalPoint {
            HorizontalPoint(x: pivot.x - (point.y - pivot.y), y: pivot.y + (point.x - pivot.x))
        }
        assertNear(turned.packages.map(\.position), board.packages.map { turn($0.position) })
        XCTAssertEqual(Set(turned.packages.map(\.angle)), [quarter])
        assertNear(turned.packagePads.flatMap(\.vertices), board.packagePads.flatMap { $0.vertices.map(turn) })
        for (pad, centre) in board.packagePadPositions {
            assertNear([turned.packagePadPositions[pad] ?? .zero], [turn(centre)], pad)
        }
        assertNear(turned.packageLines.flatMap { [$0.from, $0.to] }, board.packageLines.flatMap { [turn($0.from), turn($0.to)] })
        assertNear(turned.packageTexts.map(\.position), board.packageTexts.map { turn($0.position) })
        XCTAssertEqual(Set(turned.packageTexts.map(\.angle)), [quarter])
        let expected = ends(of: board, carried: turn)
        assertNear(turned.tracks.map(\.from), expected.from, "the ends on the pads go with them")
        assertNear(turned.tracks.map(\.to), expected.to)
        XCTAssertEqual(turned.junctions, board.junctions, "and the corners stay")
        XCTAssertEqual(turned.vias, board.vias)
    }

    func testPackagesMirroredTogetherGoToTheOtherSideWithTheTrackEndsOnTheirPads() {
        let board = ManyPackageBoard.board(packages: 60, columns: 8, padPairs: 2)
        var mirrored = board
        let passes = BoardPackageMoves.passes
        BoardPackageMoves.apply(board.packages.map { ($0.id, .mirror(about: pivot)) }, to: &mirrored)

        XCTAssertEqual(BoardPackageMoves.passes - passes, 1)
        func mirror(_ point: HorizontalPoint) -> HorizontalPoint {
            HorizontalPoint(x: 2 * pivot.x - point.x, y: point.y)
        }
        assertNear(mirrored.packages.map(\.position), board.packages.map { mirror($0.position) })
        XCTAssertTrue(mirrored.packages.allSatisfy(\.mirrored))
        assertNear(mirrored.packagePads.flatMap(\.vertices), board.packagePads.flatMap { $0.vertices.map(mirror) })
        XCTAssertEqual(Set(mirrored.packagePads.map(\.layer)), [HorizontalBoardLayers.bottomCopper])
        for (pad, centre) in board.packagePadPositions {
            assertNear([mirrored.packagePadPositions[pad] ?? .zero], [mirror(centre)], pad)
        }
        assertNear(mirrored.packageLines.flatMap { [$0.from, $0.to] }, board.packageLines.flatMap { [mirror($0.from), mirror($0.to)] })
        XCTAssertEqual(Set(mirrored.packageLines.map(\.layer)), [HorizontalBoardLayers.bottomSilkscreen])
        assertNear(mirrored.packageTexts.map(\.position), board.packageTexts.map { mirror($0.position) })
        XCTAssertTrue(mirrored.packageTexts.allSatisfy(\.mirrored))
        let expected = ends(of: board, carried: mirror)
        assertNear(mirrored.tracks.map(\.from), expected.from, "the ends on the pads go with them")
        assertNear(mirrored.tracks.map(\.to), expected.to)
        XCTAssertEqual(mirrored.tracks.map(\.layer), board.tracks.map(\.layer), "on the layer they were on")
        XCTAssertEqual(mirrored.junctions, board.junctions)
    }

    /// Whatever the packages do, together they land where one after another
    /// puts them: holes and junctions on pads carried, a fixed part left, a
    /// track of another net left on its pad.
    func testPackagesChangedTogetherLandWhereEachChangedAloneLands() {
        let columns = 8
        let board = ManyPackageBoard.withMoreOnThePads(
            ManyPackageBoard.board(packages: 40, columns: columns, padPairs: 2), columns: columns
        )
        let ids = board.packages.map(\.id)
        let changes: [(String, [(packageID: String, change: BoardPackageMoves.Change)])] = [
            ("turned", ids.map { ($0, .turn(about: pivot, by: quarter)) }),
            ("turned by an odd angle", ids.map { ($0, .turn(about: pivot, by: 5_000)) }),
            ("mirrored", ids.map { ($0, .mirror(about: pivot)) }),
            ("flipped", ids.map { ($0, .flip) }),
            // Lined up on the first column, each row's parts onto one another.
            ("lined up", ids.enumerated().map { ($1, .shift(HorizontalPoint(x: -ManyPackageBoard.origin($0, columns: columns).x, y: 0))) }),
        ]
        for (name, changes) in changes {
            var together = board
            let passes = BoardPackageMoves.passes
            BoardPackageMoves.apply(changes, to: &together)
            XCTAssertEqual(BoardPackageMoves.passes - passes, 1, name)
            var oneByOne = board
            for change in changes {
                BoardPackageMoves.apply([change], to: &oneByOne)
            }

            assertSameGeometry(together, oneByOne)
            XCTAssertNotEqual(together.packagePads, board.packagePads, name)
            XCTAssertEqual(together.packages[5].position, board.packages[5].position, "\(name): a fixed part stays")
        }
    }

    /// A part mirrored about its own middle puts each pad where the other
    /// stood. The end on the first pad goes with it and stays there, as the
    /// preview draws it; taken pad by pad, the second pad, not yet moved and
    /// on the same net, carried it back.
    func testAnEndMirroredOntoThePartsOtherPadIsNotCarriedBack() {
        var board = ManyPackageBoard.board(packages: 2, columns: 2, padPairs: 1)
        board.packagePads = board.packagePads.map { pad in
            var pad = pad
            pad.netID = "n"
            return pad
        }
        let left = ManyPackageBoard.padCentre(0, pair: 0, side: -1, columns: 2)
        let right = ManyPackageBoard.padCentre(0, pair: 0, side: 1, columns: 2)
        let free = HorizontalPoint(x: left.x, y: left.y - 3_000_000)
        board.tracks = [HorizontalSegment(id: "t", from: left, to: free, width: 200_000, layer: ManyPackageBoard.top, netID: "n")]
        board.junctions = [:]
        board.junctionNetIDs = [:]

        BoardPackageMoves.apply([(ManyPackageBoard.packageID(0), .mirror(about: ManyPackageBoard.origin(0, columns: 2)))], to: &board)

        XCTAssertEqual(board.packagePadPositions["\(ManyPackageBoard.packageID(0))/1"], right, "the first pad is where the second stood")
        XCTAssertEqual(board.tracks[0].from, right, "and the end on it went once, with it")
        XCTAssertEqual(board.tracks[0].to, free)
    }

    /// Flipped is Horizon's `flip`: the part goes to the other side where it
    /// stands, reflected across its own Y axis, whichever way it is turned.
    func testAFlippedPackageKeepsItsPlaceAndTakesTheEndsOnItsPads() {
        let board = ManyPackageBoard.board(packages: 3, columns: 3, padPairs: 2)
        let id = ManyPackageBoard.packageID(1)
        let origin = ManyPackageBoard.origin(1, columns: 3)

        var flipped = board
        BoardPackageMoves.apply([(id, .flip)], to: &flipped)
        XCTAssertEqual(flipped.packages[1].position, origin)
        XCTAssertEqual(flipped.packages[1].angle, 0)
        XCTAssertTrue(flipped.packages[1].mirrored)
        func acrossY(_ point: HorizontalPoint) -> HorizontalPoint { HorizontalPoint(x: 2 * origin.x - point.x, y: point.y) }
        for name in 1...4 {
            let centre = try? XCTUnwrap(board.packagePadPositions["\(id)/\(name)"])
            assertNear([flipped.packagePadPositions["\(id)/\(name)"] ?? .zero], [acrossY(centre ?? .zero)], "pad \(name)")
        }
        XCTAssertEqual(Set(flipped.packagePads.filter { $0.id.hasPrefix(id) }.map(\.layer)), [HorizontalBoardLayers.bottomCopper])
        // The route into its first pad, and the one out of its second.
        assertNear([flipped.tracks[1].to], [acrossY(board.tracks[1].to)], "the end on its left pad")
        assertNear([flipped.tracks[4].from], [acrossY(board.tracks[4].from)], "the end on its right pad")
        XCTAssertEqual(flipped.tracks[0], board.tracks[0], "a track on another part's pad stays")

        // Turned a quarter first, its own Y axis lies along the board's X.
        var turned = board
        BoardPackageMoves.apply([(id, .turn(about: origin, by: quarter))], to: &turned)
        var turnedAndFlipped = turned
        BoardPackageMoves.apply([(id, .flip)], to: &turnedAndFlipped)
        XCTAssertEqual(turnedAndFlipped.packages[1].angle, quarter)
        for name in 1...4 {
            let before = turned.packagePadPositions["\(id)/\(name)"] ?? .zero
            assertNear(
                [turnedAndFlipped.packagePadPositions["\(id)/\(name)"] ?? .zero],
                [HorizontalPoint(x: before.x, y: 2 * origin.y - before.y)], "pad \(name), turned"
            )
        }
    }

    /// The inspector's Angle turns the part where it stands and leaves the
    /// copper on its pads, a fixed part too, as it did set on each alone.
    func testAnAngleSetOnAPackageTurnsItAndLeavesTheCopper() {
        var board = ManyPackageBoard.board(packages: 3, columns: 3, padPairs: 1)
        board.packages[1].fixed = true
        let origin = ManyPackageBoard.origin(1, columns: 3)
        var turned = board
        let passes = BoardPackageMoves.passes
        BoardPackageMoves.apply(board.packages.map { ($0.id, .angle(quarter)) }, to: &turned)

        XCTAssertEqual(BoardPackageMoves.passes - passes, 0, "no track or junction is read: none goes")
        XCTAssertEqual(turned.packages.map(\.angle), [quarter, quarter, quarter])
        XCTAssertEqual(turned.packages.map(\.position), board.packages.map(\.position))
        let pad = board.packagePadPositions["\(ManyPackageBoard.packageID(1))/2"] ?? .zero
        assertNear(
            [turned.packagePadPositions["\(ManyPackageBoard.packageID(1))/2"] ?? .zero],
            [HorizontalPoint(x: origin.x - (pad.y - origin.y), y: origin.y + (pad.x - origin.x))]
        )
        XCTAssertEqual(turned.tracks, board.tracks)
    }

    func testXYAngleAndFlippedSetOnPackagesAreChangesOfPlaceForThemAll() throws {
        var board = ManyPackageBoard.board(packages: 6, columns: 3, padPairs: 1)
        board.packages[2].mirrored = true
        // A locked track on the fifth part's pad holds it.
        board.tracks[7].locked = true
        let refs = board.packages.map { HorizontalSelectableRef(id: $0.id.uppercased(), type: .boardPackage) }
        func changes(_ propertyID: String, _ value: HorizontalSelectionPropertyValue) -> [BoardPackageMoves.Change]? {
            BoardPackagePlacementEdit.changes(value, propertyID: propertyID, of: refs, in: board)?.map(\.change)
        }

        let pitch = ManyPackageBoard.pitch
        XCTAssertEqual(changes("positionX", .length(1_000_000)), [
            .shift(.init(x: 1_000_000, y: 0)), .shift(.init(x: 1_000_000 - pitch, y: 0)), .shift(.init(x: 1_000_000 - 2 * pitch, y: 0)),
            .shift(.init(x: 1_000_000, y: 0)), .shift(.init(x: 1_000_000 - 2 * pitch, y: 0)),
        ], "each to the X asked for, but the part the locked track holds")
        XCTAssertEqual(changes("positionY", .length(500_000))?.first, .shift(.init(x: 0, y: 500_000)))
        XCTAssertEqual(changes("angle", .angle(quarter + 65_536)), Array(repeating: .angle(quarter), count: 5))
        XCTAssertEqual(changes("flipped", .bool(true)), Array(repeating: .flip, count: 4), "the one flipped already stays")
        XCTAssertEqual(changes("flipped", .bool(false)), [.flip])

        XCTAssertNil(changes("fixed", .bool(true)), "any other property is set on each as before")
        XCTAssertNil(changes("positionX", .bool(true)))
        XCTAssertNil(BoardPackagePlacementEdit.changes(
            .length(0), propertyID: "positionX", of: [HorizontalSelectableRef(id: board.vias[0].id, type: .via)], in: board
        ))
    }

    /// Junctions carried from several pads to one point fold there one group
    /// after another, the last to land kept, as they did package by package;
    /// one that lands where another stood, itself about to go, leaves it be.
    func testJunctionsCarriedToOnePointFoldInTheOrderTheyLand() {
        var board = ManyPackageBoard.board(packages: 4, columns: 4, padPairs: 1)
        board.tracks = []
        board.vias = []
        let (a, b, c) = (HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 1_000_000, y: 0), HorizontalPoint(x: 2_000_000, y: 0))
        let landing = HorizontalPoint(x: 5_000_000, y: 5_000_000)
        board.junctions = ["at-a": a, "at-b": b, "at-c": c, "there": landing]
        board.junctionNetIDs = ["at-b": "net-b"]

        var folded = board
        BoardTrackRouting.carryJunctions([(["at-a"], landing, "net-a"), (["at-b"], landing, nil)], board: &folded)
        XCTAssertEqual(folded.junctions, ["at-b": landing, "at-c": c])
        XCTAssertEqual(folded.junctionNetIDs, ["at-b": "net-b"])

        var swapped = board
        BoardTrackRouting.carryJunctions([(["at-a"], b, nil), (["at-b"], c, nil), (["at-c"], a, nil)], board: &swapped)
        XCTAssertEqual(swapped.junctions, ["at-a": b, "at-b": c, "at-c": a, "there": landing], "each went once, and none took another in")
    }

    func testPackagesNamedInARowShareAPassAndTheNextRowTakesAnother() {
        let board = ManyPackageBoard.board(packages: 12, columns: 4, padPairs: 1)
        var changed = board
        var run = BoardPackageMoves.Run()
        let passes = BoardPackageMoves.passes
        for package in board.packages.prefix(6) {
            run.add(package.id, .turn(about: pivot, by: quarter))
        }
        run.finish(on: &changed)
        run.finish(on: &changed)
        XCTAssertEqual(BoardPackageMoves.passes - passes, 1, "six in a row, one pass; nothing more to do, none")
        for package in board.packages.suffix(6) {
            run.add(package.id, .turn(about: pivot, by: quarter))
        }
        run.finish(on: &changed)
        XCTAssertEqual(BoardPackageMoves.passes - passes, 2)

        var together = board
        BoardPackageMoves.apply(board.packages.map { ($0.id, .turn(about: pivot, by: quarter)) }, to: &together)
        assertSameGeometry(changed, together)
    }

    func testObjectPositionsGiveThePointsThatPlaceEachKindOfObject() {
        var board = ManyPackageBoard.withMoreOnThePads(ManyPackageBoard.board(packages: 6, columns: 3, padPairs: 1), columns: 3)
        board.tracks[2].center = HorizontalPoint(x: 1, y: 2)
        board.texts = [HorizontalText(id: "free", text: "free", position: .init(x: 5, y: 6), size: 1_000_000, layer: ManyPackageBoard.top)]
        var positions = BoardObjectPositions(of: board)
        func points(_ id: String, _ type: HorizontalObjectType) -> [HorizontalPoint]? {
            positions.anchorPoints(of: HorizontalSelectableRef(id: id, type: type))
        }

        XCTAssertEqual(points(board.packages[4].id.uppercased(), .boardPackage), [board.packages[4].position])
        XCTAssertEqual(points(board.tracks[1].id, .track), [board.tracks[1].from, board.tracks[1].to])
        XCTAssertEqual(points(board.tracks[2].id, .track), [board.tracks[2].from, board.tracks[2].to, HorizontalPoint(x: 1, y: 2)], "an arc's centre too")
        XCTAssertEqual(points(board.vias[0].id, .via), [board.vias[0].position])
        XCTAssertEqual(points(board.packageHoles[0].id, .boardHole), [board.packageHoles[0].position])
        XCTAssertEqual(points(board.viaHoles[0].id, .boardHole), [board.viaHoles[0].position])
        XCTAssertEqual(points("free", .text), [HorizontalPoint(x: 5, y: 6)])
        XCTAssertEqual(points(board.packageTexts[3].id, .text), [board.packageTexts[3].position])
        let junction = board.junctions.keys.sorted()[0]
        XCTAssertEqual(points(junction.uppercased(), .junction), [board.junctions[junction] ?? .zero])
        XCTAssertEqual(points("missing", .track), [], "nothing places an object the board lacks")
        XCTAssertNil(points(board.packagePads[0].id, .pad), "a kind the canvas works out itself")
    }
}

#if os(macOS)
/// The board canvas's own turn, mirror, lining up and inspector edits of
/// many packages: each reads the board's tracks and junctions once, takes
/// the track ends on the pads along, and is one undo step.
@MainActor
final class BoardManyPackageTurnCanvasTests: XCTestCase {
    private let count = 240
    private let padPairs = 2

    /// The canvas over the board of many packages, all of them selected.
    private func canvasWithEveryPackageSelected() async throws -> ManyPackageCanvas {
        let canvas = ManyPackageCanvas(ManyPackageBoard.board(packages: count, padPairs: padPairs))
        try await canvas.mount()
        await canvas.selectComponents(count)
        return canvas
    }

    /// Whether every routed pad of `board` still has its track's end on it.
    private func assertEndsAreOnTheirPads(_ board: HorizontalBoard, file: StaticString = #filePath, line: UInt = #line) {
        for serial in 0..<((count - 1) * padPairs) {
            let pads = ManyPackageBoard.routedPads(serial, padPairs: padPairs)
            assertNear([board.tracks[2 * serial].from], [board.packagePadPositions[pads.from] ?? .zero], "route \(serial) out", file: file, line: line)
            assertNear([board.tracks[2 * serial + 1].to], [board.packagePadPositions[pads.to] ?? .zero], "route \(serial) in", file: file, line: line)
        }
    }

    /// Runs `change` on the canvas and returns the board it leaves, having
    /// checked that it read the tracks and junctions once and that one undo
    /// takes it all back.
    private func boardAfter(_ canvas: ManyPackageCanvas, _ change: () -> Void) async throws -> HorizontalBoard {
        let passes = BoardPackageMoves.passes
        change()
        let committed = await canvas.settle { canvas.committed.count == 1 }
        XCTAssertTrue(committed)
        XCTAssertEqual(BoardPackageMoves.passes - passes, 1, "the board's tracks and junctions are read once, not once a pad or a package")
        let changed = try XCTUnwrap(canvas.committed.last)
        XCTAssertEqual(changed.junctions, canvas.source.junctions, "the corners stay")
        XCTAssertEqual(changed.vias.map(\.position), canvas.source.vias.map(\.position))

        XCTAssertTrue(canvas.undo.canUndo)
        canvas.undo.undo()
        let undone = await canvas.settle { canvas.committed.count == 2 }
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(canvas.committed.last)
        XCTAssertEqual(restored.packages, canvas.source.packages)
        XCTAssertEqual(restored.packagePads, canvas.source.packagePads)
        XCTAssertEqual(restored.tracks.map(\.from), canvas.source.tracks.map(\.from))
        XCTAssertEqual(restored.tracks.map(\.to), canvas.source.tracks.map(\.to))
        XCTAssertFalse(canvas.undo.canUndo, "it was all one step")
        return changed
    }

    func testTurningManyPackagesReadsTheBoardOnceAndIsOneUndoStep() async throws {
        let canvas = try await canvasWithEveryPackageSelected()
        defer { canvas.close() }
        let turned = try await boardAfter(canvas) { canvas.actions?.dispatch(.rotateSelectionAroundCenter) }

        XCTAssertEqual(Set(turned.packages.map(\.angle)), [65_536 - ManyPackageBoard.quarterTurn], "a quarter turn clockwise")
        // About one point: every part as far from the first as it was, down
        // where it was along.
        let (first, was) = (turned.packages[0].position, canvas.source.packages[0].position)
        assertNear(
            turned.packages.map { $0.position - first },
            canvas.source.packages.map { HorizontalPoint(x: $0.position.y - was.y, y: -($0.position.x - was.x)) }
        )
        assertEndsAreOnTheirPads(turned)
    }

    func testMirroringManyPackagesReadsTheBoardOnceAndIsOneUndoStep() async throws {
        let canvas = try await canvasWithEveryPackageSelected()
        defer { canvas.close() }
        let mirrored = try await boardAfter(canvas) { canvas.actions?.dispatch(.mirrorSelectionHorizontal) }

        XCTAssertTrue(mirrored.packages.allSatisfy(\.mirrored))
        let (first, was) = (mirrored.packages[0].position, canvas.source.packages[0].position)
        assertNear(
            mirrored.packages.map { $0.position - first },
            canvas.source.packages.map { HorizontalPoint(x: -($0.position.x - was.x), y: $0.position.y - was.y) }
        )
        XCTAssertEqual(Set(mirrored.packagePads.map(\.layer)), [HorizontalBoardLayers.bottomCopper])
        // The grid mirrors onto itself, each pad to where another stood, and
        // every end is still on the pad it was on.
        assertEndsAreOnTheirPads(mirrored)
    }

    func testLiningUpManyPackagesReadsTheBoardOnceAndIsOneUndoStep() async throws {
        let canvas = try await canvasWithEveryPackageSelected()
        defer { canvas.close() }
        let alignable = await canvas.settle { canvas.actions?.alignableSelectionCount == self.count }
        XCTAssertTrue(alignable)
        let aligned = try await boardAfter(canvas) { canvas.actions?.dispatch(.alignSelection(.left)) }

        XCTAssertEqual(Set(aligned.packages.map(\.position.x)).count, 1, "every part on the first column")
        XCTAssertEqual(aligned.packages.map(\.position.y), canvas.source.packages.map(\.position.y))
        assertEndsAreOnTheirPads(aligned)
    }

    func testFlippingManyPackagesInTheInspectorReadsTheBoardOnceAndIsOneUndoStep() async throws {
        let canvas = try await canvasWithEveryPackageSelected()
        defer { canvas.close() }
        let flipped = try await boardAfter(canvas) {
            canvas.command = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
                ref: HorizontalSelectableRef(id: ManyPackageBoard.packageID(0), type: .boardPackage), type: .boardPackage,
                propertyID: "flipped", value: .bool(true), applyToAll: true
            ))
        }

        XCTAssertTrue(flipped.packages.allSatisfy(\.mirrored))
        XCTAssertEqual(flipped.packages.map(\.position), canvas.source.packages.map(\.position), "each where it stood")
        assertEndsAreOnTheirPads(flipped)
    }

    /// Select All names the tracks, junctions and vias before the packages
    /// and the packages in a row, so the turn still reads the board once for
    /// them.
    func testTurningEverythingOnTheBoardStillTurnsThePackagesInOnePass() async throws {
        let canvas = ManyPackageCanvas(ManyPackageBoard.board(packages: count, padPairs: padPairs))
        try await canvas.mount()
        defer { canvas.close() }
        canvas.actions?.dispatch(.selectAll)
        let selected = await canvas.settle { canvas.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)

        let passes = BoardPackageMoves.passes
        canvas.actions?.dispatch(.rotateSelectionAroundCenter)
        let committed = await canvas.settle { canvas.committed.count == 1 }
        XCTAssertTrue(committed)
        XCTAssertEqual(BoardPackageMoves.passes - passes, 1)
        let turned = try XCTUnwrap(canvas.committed.last)
        XCTAssertEqual(Set(turned.packages.map(\.angle)), [65_536 - ManyPackageBoard.quarterTurn])
        assertEndsAreOnTheirPads(turned)
        XCTAssertNotEqual(turned.junctions, canvas.source.junctions, "the corners turned with the rest")
    }

    /// Not a test of behaviour: prints how long a turn, a mirror and lining
    /// up take on every package, for each count in
    /// `HORIZONTAL_TURN_TIMING_COUNTS` (say "200,400,800"; twice the parts
    /// should take twice the time). `HORIZONTAL_TURN_TIMING_PAD_PAIRS` sets
    /// the pads on each part, and `HORIZONTAL_TURN_TIMING_SELECT_ALL` takes
    /// the tracks, junctions and vias along.
    func testTimingOfTurningMirroringAndLiningUpEveryPackage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let counts = environment["HORIZONTAL_TURN_TIMING_COUNTS"]?.split(separator: ",").compactMap({ Int($0) }),
              !counts.isEmpty else {
            throw XCTSkip("set HORIZONTAL_TURN_TIMING_COUNTS to time a turn")
        }
        let padPairs = environment["HORIZONTAL_TURN_TIMING_PAD_PAIRS"].flatMap { Int($0) } ?? 1
        let commands: [(name: String, command: HorizontalCanvasCommand)] = [
            ("turn", .rotateSelectionAroundCenter), ("mirror x", .mirrorSelectionHorizontal),
            ("mirror y", .mirrorSelectionVertical), ("align left", .alignSelection(.left)),
        ]
        for count in counts {
            for (name, command) in commands {
                let canvas = ManyPackageCanvas(ManyPackageBoard.board(packages: count, columns: 21, padPairs: padPairs))
                try await canvas.mount()
                defer { canvas.close() }
                _ = await canvas.untilIdle()
                if environment["HORIZONTAL_TURN_TIMING_SELECT_ALL"] != nil {
                    canvas.actions?.dispatch(.selectAll)
                    let selected = await canvas.settle(120) { canvas.actions?.canMoveSelection == true }
                    XCTAssertTrue(selected)
                } else {
                    await canvas.selectComponents(count)
                }
                _ = await canvas.untilIdle()

                let clock = Date()
                canvas.actions?.dispatch(command)
                let inside = Date().timeIntervalSince(clock)
                let committed = await canvas.settle(600) { canvas.committed.count == 1 }
                XCTAssertTrue(committed, name)
                let after = await canvas.untilIdle()
                let total = Date().timeIntervalSince(clock)
                print(String(
                    format: "TURN TIMING %@ packages %4d pads %5d tracks %5d  command %9.1f ms  busy after %8.1f ms  to idle %9.1f ms",
                    name.padding(toLength: 10, withPad: " ", startingAt: 0), count, canvas.source.packagePads.count,
                    canvas.source.tracks.count, inside * 1000, after * 1000, total * 1000
                ))
            }
        }
    }
}
#endif
