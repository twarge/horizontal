import XCTest
import CryptoKit
@testable import HorizontalNative

/// Golden plane fills captured from a real board.
///
/// The prerequisite for ever rewriting the pour: it is
/// the most behaviour-critical code in the project, a fill that differs is not a
/// cosmetic difference but a different board, and the synthetic cases in
/// `BoardPlanePourTests` only catch gross regressions. A real board brings what
/// they cannot — hundreds of thermal pads, several priority tiers, planes on four
/// layers, and cutouts in the thousands.
///
/// The golden records per-plane fragment and hole counts and filled AREA, never
/// coordinates. That is a hard requirement, not a size optimisation: a fill's
/// vertex count is not reproducible between processes (see `PlaneFillDigest`), so
/// a golden built from geometry would fail at random. It also means this table
/// says how much copper was poured, not where any of it is.
///
/// The board lives outside the repository, so these skip when it is absent —
/// including on CI. Point `HORIZONTAL_GOLDEN_BOARD` at a `.hprj` to use another.
final class PlaneFillGoldenTests: XCTestCase {
    private static let defaultBoardPath =
        "/Users/kornack/Repositories/randi/Randi Short Horizon/Randi Short.hprj"

    private func loadGoldenBoard() throws -> HorizontalBoard {
        let path = ProcessInfo.processInfo.environment["HORIZONTAL_GOLDEN_BOARD"]
            ?? Self.defaultBoardPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("golden board not present at \(path)")
        }

        // The board is a real design that lives outside this repository and gets
        // edited. Comparing today's fills against yesterday's board reports a
        // copper difference that reads as a code regression and is not one — it
        // happened on the first day this existed. So verify the INPUT first and
        // skip with an instruction rather than failing on the output.
        let boardJSON = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("board.json")
        if let data = try? Data(contentsOf: boardJSON) {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == randiShortBoardSHA256 else {
                throw XCTSkip("""
                    The golden board has been edited since these fills were captured \
                    (board.json is \(digest.prefix(12))…, expected \
                    \(randiShortBoardSHA256.prefix(12))…). This is not a code failure. \
                    Re-capture PlaneFillGoldenData.swift from the current board, \
                    reviewing the area changes to confirm they are the edits you made.
                    """)
            }
        }

        let project = try HorizontalProject.load(from: URL(fileURLWithPath: path))
        return try XCTUnwrap(project.board, "golden board carries no board")
    }

    /// Area is compared to a tolerance rather than exactly: it is a sum of cross
    /// products over thousands of vertices, so the last bits are not worth
    /// pinning. One square micron is far below anything fabricable, and around
    /// six orders of magnitude above the summation noise — at these coordinates a
    /// double holds area to roughly 1e-12 mm².
    private let areaToleranceMM2 = 1e-6

    func testPouredFillsMatchTheGolden() throws {
        let board = try loadGoldenBoard()
        let poured = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board)
        let byID = Dictionary(uniqueKeysWithValues: poured.planes.map { ($0.id, $0) })

        XCTAssertEqual(poured.planes.count, randiShortPlaneFills.count,
                       "the golden was captured from a board with a different plane count")

        for golden in randiShortPlaneFills {
            let plane = try XCTUnwrap(byID[golden.id], "golden plane \(golden.id) is missing")
            let digest = PlaneFillDigest(plane)
            let label = "\(golden.id.prefix(8)) (layer \(golden.layer), priority \(golden.priority))"

            XCTAssertEqual(digest.fragmentCount, golden.fragments, "\(label): fragment count")
            XCTAssertEqual(digest.holeCount, golden.holes, "\(label): hole count")
            XCTAssertEqual(digest.areaMM2, golden.areaMM2, accuracy: areaToleranceMM2,
                           "\(label): poured copper area")
        }
    }

    /// The cache must not change what is poured, only how long it takes — so a
    /// warm pour has to match the same golden.
    func testCachedPourMatchesTheGolden() throws {
        let board = try loadGoldenBoard()
        let warm = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board, cache: HorizontalPlanePourCache())
        let second = HorizontalBoardPlaneUpdater.updateAllPlanes(in: warm.board, cache: warm.cache).board
        let byID = Dictionary(uniqueKeysWithValues: second.planes.map { ($0.id, $0) })

        for golden in randiShortPlaneFills {
            let digest = PlaneFillDigest(try XCTUnwrap(byID[golden.id]))
            XCTAssertEqual(digest.fragmentCount, golden.fragments, "\(golden.id.prefix(8)): fragments")
            XCTAssertEqual(digest.areaMM2, golden.areaMM2, accuracy: areaToleranceMM2,
                           "\(golden.id.prefix(8)): area")
        }
    }

    /// Guards the harness itself: if the digest were not reproducible, every
    /// failure above would be noise. Pouring twice in one process must agree
    /// exactly — no tolerance.
    func testTheDigestIsReproducible() throws {
        let board = try loadGoldenBoard()
        let first = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board).planes.map(PlaneFillDigest.init)
        let second = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board).planes.map(PlaneFillDigest.init)

        XCTAssertEqual(first.map(\.fragmentCount), second.map(\.fragmentCount))
        XCTAssertEqual(first.map(\.holeCount), second.map(\.holeCount))
        XCTAssertEqual(first.map(\.areaMM2), second.map(\.areaMM2))
    }

    /// The board the golden was captured from must still be the board being
    /// poured — otherwise the table silently stops meaning anything.
    func testTheGoldenDescribesThisBoard() throws {
        let board = try loadGoldenBoard()
        for golden in randiShortPlaneFills {
            let plane = try XCTUnwrap(board.planes.first { $0.id == golden.id })
            XCTAssertEqual(plane.layer, golden.layer, "\(golden.id.prefix(8)): layer moved")
            XCTAssertEqual(plane.priority, golden.priority, "\(golden.id.prefix(8)): priority moved")
        }
    }
}
