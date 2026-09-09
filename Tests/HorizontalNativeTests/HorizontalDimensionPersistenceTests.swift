import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Drawing and deleting a board dimension, through the writer the canvas
/// saves with.
///
/// `patchDimensions` began as an update-only patcher: it looked each entry up
/// by id and skipped anything it could not find, and it returned early when
/// the board had no `dimensions` key at all. Neither shows until something
/// makes a dimension the file has never seen — which the Draw Dimension tool
/// does — and then the tool draws on screen and writes nothing. These fail
/// against that writer, which is the point of them.
final class HorizontalDimensionPersistenceTests: XCTestCase {
    private var root: URL!
    private var url: URL!
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-dimensions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }

        url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
        project = try HorizontalProject.load(from: url)
    }

    private func drawn(_ id: String = "dimension-1", mode: HorizontalDimensionMode = .distance) -> HorizontalDimension {
        HorizontalDimension(
            id: id,
            p0: HorizontalPoint(x: 0, y: 0),
            p1: HorizontalPoint(x: 10_000_000, y: 0),
            labelDistance: 1_000_000,
            labelSize: 1_500_000,
            mode: mode
        )
    }

    /// Applies an edited board the way the canvas does, and reads the project
    /// back from what was written.
    @discardableResult
    private func save(_ board: HorizontalBoard) throws -> HorizontalBoard {
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        return try XCTUnwrap(project.board)
    }

    func testADrawnDimensionSurvivesTheSave() throws {
        var board = try XCTUnwrap(project.board)
        XCTAssertTrue(board.dimensions.isEmpty, "the template board carries none, which is the case that used to fail")
        board.dimensions.append(drawn())

        let saved = try save(board)
        let dimension = try XCTUnwrap(saved.dimensions.first)
        XCTAssertEqual(saved.dimensions.count, 1)
        XCTAssertEqual(dimension.p0, HorizontalPoint(x: 0, y: 0), "the geometry too, not only the label properties")
        XCTAssertEqual(dimension.p1, HorizontalPoint(x: 10_000_000, y: 0))
        XCTAssertEqual(dimension.labelDistance, 1_000_000)
        XCTAssertEqual(dimension.labelSize, 1_500_000)
        XCTAssertEqual(dimension.mode, .distance)
        XCTAssertEqual(dimension.length, 10_000_000, "so it measures what was drawn")
    }

    func testEditingOneKeepsWritingIt() throws {
        var board = try XCTUnwrap(project.board)
        board.dimensions.append(drawn())
        board = try save(board)

        board.dimensions[0].mode = .horizontal
        board.dimensions[0].labelSize = 2_000_000
        let saved = try save(board)
        XCTAssertEqual(saved.dimensions.count, 1, "edited, not duplicated")
        XCTAssertEqual(saved.dimensions.first?.mode, .horizontal)
        XCTAssertEqual(saved.dimensions.first?.labelSize, 2_000_000)
    }

    /// Deleting says so explicitly, because the writer keeps entries the model
    /// does not know about — a parser that dropped one must not read as a user
    /// deleting it.
    func testDeletingOneNeedsTheRemovalFlagged() throws {
        var board = try XCTUnwrap(project.board)
        board.dimensions.append(drawn())
        board = try save(board)

        var withoutFlag = board
        withoutFlag.dimensions.removeAll()
        XCTAssertEqual(try save(withoutFlag).dimensions.count, 1, "absence alone is not deletion")

        var flagged = try XCTUnwrap(project.board)
        flagged.dimensions.removeAll()
        flagged.removedDimensionIDs = ["dimension-1"]
        XCTAssertTrue(try save(flagged).dimensions.isEmpty)
    }

    /// A panel draws another board's dimensions with prefixed ids. Writing
    /// those into this board's file would copy another board's geometry in.
    func testAPanelsDimensionsAreNotWrittenIntoThisBoard() throws {
        var board = try XCTUnwrap(project.board)
        board.dimensions.append(drawn("panel-1/dimension-9"))

        XCTAssertTrue(try save(board).dimensions.isEmpty, "the panel's copy belongs to the panel's own file")
    }
}
