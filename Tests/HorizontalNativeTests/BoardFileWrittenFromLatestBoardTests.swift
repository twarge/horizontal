import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The board's file is written from the latest board when the archive is
/// read, not after each commit (`HorizontalBoardFileWrite`): boards that
/// another followed before anything read the file are never written. The
/// file that gives loads as the board that writing every one of them in turn
/// gives, and keeps what the file held that the app doesn't know.
final class BoardFileWrittenFromLatestBoardTests: XCTestCase {
    private let junction = "aaaaaaaa-0000-4000-8000-000000000001"
    private let first = "bbbbbbbb-0000-4000-8000-000000000001"
    private let second = "bbbbbbbb-0000-4000-8000-000000000002"
    private let unknownKey = "from_a_newer_horizon"

    /// R1, R2 and R3 placed, R1's pad 2 routed to R2's pad 1 through a
    /// junction, and on the first of the two tracks a key the app has never
    /// heard of.
    private func fixture() throws -> BlockLayoutFixture {
        let fixture = try BlockLayoutFixture(instances: 1)
        let root = fixture.root
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let instance = try XCTUnwrap(fixture.instances.first)
        try fixture.addCopper(
            junctions: [junction: HorizontalPoint(x: 2_500_000, y: 2_000_000)],
            tracks: [
                first: (from: try fixture.padEnd(instance, "R1", 2), to: fixture.junctionEnd(junction), layer: 0),
                second: (from: fixture.junctionEnd(junction), to: try fixture.padEnd(instance, "R2", 1), layer: 0),
            ]
        )
        var json = try fixture.boardJSON()
        var tracks = json.dictionaryMap("tracks")
        tracks[first]?[unknownKey] = 7
        json["tracks"] = tracks
        try fixture.putBoard(json)
        // The file as the app writes it, so the edits below are all that
        // each write changes.
        try fixture.write(try fixture.board)
        return fixture
    }

    /// Three edits, one after the other: a part moved and a track locked;
    /// the other track deleted; that track put back and the lock taken off.
    private func edits(of board: HorizontalBoard) throws -> [HorizontalBoard] {
        let firstIndex = try XCTUnwrap(board.tracks.firstIndex { $0.id.lowercased() == first })
        let secondIndex = try XCTUnwrap(board.tracks.firstIndex { $0.id.lowercased() == second })
        var moved = board
        moved.packages[2].position.x += 3_000_000
        moved.tracks[secondIndex].locked = true
        var deleted = moved
        deleted.tracks.remove(at: firstIndex)
        var restored = moved
        restored.tracks[secondIndex].locked = false
        restored.tracks[secondIndex].width = 300_000
        restored.tracks[secondIndex].widthFromRules = false
        return [moved, deleted, restored]
    }

    private func boardJSON(_ archive: HorizontalProjectArchive) throws -> JSONDictionary {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    /// What of a board its file holds and a load gives back: where its parts
    /// are and its copper.
    private func summary(_ archive: HorizontalProjectArchive) throws -> [String] {
        let board = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        let packages = board.packages.map { "package \($0.id.lowercased()) \($0.position.x) \($0.position.y) \($0.angle) \($0.mirrored)" }
        let tracks = board.tracks.map {
            "track \($0.id.lowercased()) \($0.from.x),\($0.from.y) \($0.to.x),\($0.to.y) \($0.width) \($0.layer ?? -1) \($0.locked) "
                + "\($0.fromJunctionID?.lowercased() ?? "-") \($0.toJunctionID?.lowercased() ?? "-")"
        }
        let junctions = board.junctions.map { "junction \($0.key.lowercased()) \($0.value.x) \($0.value.y)" }
        return (packages + tracks + junctions).sorted()
    }

    func testOneWriteFromTheLastBoardLoadsAsTheBoardWrittenEditByEdit() throws {
        let fixture = try fixture()
        let boards = try edits(of: try fixture.board)

        var editByEdit = fixture.archive
        for board in boards {
            XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: board, in: fixture.project, to: &editByEdit))
        }
        var document = HorizontalProjectDocument()
        document.archive = fixture.archive
        for board in boards {
            document.deferBoardWrite(board, in: fixture.project)
        }
        XCTAssertTrue(document.hasDeferredEdit)
        XCTAssertEqual(document.settledArchive, fixture.archive, "nothing is written until the archive is read")
        let fromTheLast = document.archive

        let loaded = try summary(fromTheLast)
        XCTAssertEqual(loaded, try summary(editByEdit))
        XCTAssertTrue(loaded.contains { $0.hasPrefix("track \(first)") }, "\(loaded)")
        XCTAssertTrue(loaded.contains { $0.hasPrefix("track \(second)") && $0.contains(" 300000.0 ") }, "\(loaded)")
        XCTAssertNotEqual(loaded, try summary(fixture.archive), "and it is not the board before the edits")
    }

    /// The track deleted and put back was never out of the file, so it keeps
    /// the key the app does not know.
    func testAnObjectDeletedAndPutBackBetweenWritesKeepsWhatTheAppDoesNotKnow() throws {
        let fixture = try fixture()
        XCTAssertEqual(try boardJSON(fixture.archive).dictionaryMap("tracks")[first]?[unknownKey] as? Int, 7, "precondition")
        var document = HorizontalProjectDocument()
        document.archive = fixture.archive
        for board in try edits(of: try fixture.board) {
            document.deferBoardWrite(board, in: fixture.project)
        }

        let tracks = try boardJSON(document.archive).dictionaryMap("tracks")

        XCTAssertEqual(tracks[first]?[unknownKey] as? Int, 7)
        XCTAssertEqual(tracks.count, 2)
    }

    func testOneDeferredWriteGivesTheBytesWritingItAtOnceGives() throws {
        let fixture = try fixture()
        let moved = try XCTUnwrap(try edits(of: try fixture.board).first)
        var atOnce = fixture.archive
        XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: moved, in: fixture.project, to: &atOnce))
        var document = HorizontalProjectDocument()
        document.archive = fixture.archive

        document.deferBoardWrite(moved, in: fixture.project)

        XCTAssertEqual(document.archive, atOnce)
        // And the same board written again changes nothing.
        var again = document.archive
        XCTAssertFalse(try HorizontalProjectJSONApplicator.apply(board: moved, in: fixture.project, to: &again))
        XCTAssertEqual(again, atOnce)
    }

    /// Not a test of behaviour: what the board file of one commit costs the
    /// main thread on the many-package board, written in the commit as it
    /// was and left to be written as it is. `HORIZONTAL_BOARD_FILE_TIMING_COUNTS`
    /// names the package counts ("1000,2000"),
    /// `HORIZONTAL_BOARD_FILE_TIMING_PAD_PAIRS` the pad pairs on each (4).
    @MainActor
    func testWhatACommitsBoardFileCostsTheMainThread() async throws {
        let environment = ProcessInfo.processInfo.environment
        let counts = environment["HORIZONTAL_BOARD_FILE_TIMING_COUNTS"]?.split(separator: ",").compactMap { Int($0) } ?? []
        guard !counts.isEmpty else { throw XCTSkip("set HORIZONTAL_BOARD_FILE_TIMING_COUNTS") }
        let padPairs = environment["HORIZONTAL_BOARD_FILE_TIMING_PAD_PAIRS"].flatMap { Int($0) } ?? 4
        func milliseconds(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        for count in counts {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-file-timing-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("Timing.horizontal")
            try HorizontalProjectArchive.newProject().write(to: url)
            var archive = try HorizontalProjectArchive.completeProject(from: url)
            let project = try HorizontalProject.load(from: url)
            let columns = max(Int(Double(count).squareRoot().rounded()), 4)
            var board = ManyPackageBoard.board(packages: count, columns: columns, padPairs: padPairs)
            board.url = try XCTUnwrap(project.board?.url)
            board = HorizontalBoardConnectivity.recompute(board)
            _ = try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
            let fileSize = archive.regularFileData(relativePath: board.url.lastPathComponent)?.count ?? 0
            // One part a step on, and a track with it.
            var moved = board
            moved.packages[count / 2].position.y += 1_000_000
            moved.tracks[moved.tracks.count / 2].width += 10_000

            var inTheCommit = Double.infinity, deferring = Double.infinity, behind = Double.infinity, firstReader = Double.infinity
            for _ in 0..<3 {
                var written = archive
                inTheCommit = min(inTheCommit, try milliseconds {
                    XCTAssertTrue(try HorizontalProjectJSONApplicator.apply(board: moved, in: project, to: &written))
                })
                var document = HorizontalProjectDocument()
                document.archive = archive
                deferring = min(deferring, milliseconds { document.deferBoardWrite(moved, in: project) })
                let start = DispatchTime.now().uptimeNanoseconds
                let error = await document.writeDeferredEdit()
                behind = min(behind, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                XCTAssertNil(error)
                XCTAssertFalse(document.hasDeferredEdit)
                XCTAssertEqual(document.settledArchive, written, "the same file either way")
                var asked = HorizontalProjectDocument()
                asked.archive = archive
                asked.deferBoardWrite(moved, in: project)
                firstReader = min(firstReader, milliseconds { _ = asked.archive })
            }
            print(String(
                format: "BOARD FILE packages %5d tracks %6d file %6.2f MB | written in the commit %8.1f ms on the main thread | left to be written: %6.3f ms in the commit, %8.1f ms behind it off the main thread, or %8.1f ms for a reader that gets there first",
                count, board.tracks.count, Double(fileSize) / 1e6, inTheCommit, deferring, behind, firstReader
            ))
        }
    }
}
