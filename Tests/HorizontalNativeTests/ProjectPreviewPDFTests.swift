import Metal
import PDFKit
import XCTest
@testable import HorizontalNative

/// The PDF Quick Look shows of a project: the board in 3D from the top and
/// the bottom, then the schematic's pages, then the board drawing.
final class ProjectPreviewPDFTests: XCTestCase {
    @MainActor
    func testThePreviewOpensWithTheBoardFromTheTopAndTheBottom() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("the 3D pages need a Metal device")
        }
        let fixture = try BlockLayoutFixture()
        defer { fixture.remove() }
        let project = fixture.project
        let board = try XCTUnwrap(project.board)
        let sheets = HorizontalExportBackend.schematicPages(of: project).count
        XCTAssertGreaterThan(sheets, 0)

        let document = try await HorizontalProjectPreviewPDF.document(for: project)
        XCTAssertEqual(document.pageCount, 2 + sheets + 1)

        // The 3D pages are the board's shape, the longer side A4's.
        let dimensions = horizonSceneBoardDimensions(for: board)
        for index in 0..<2 {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(max(bounds.width, bounds.height), HorizontalProjectPreviewPDF.viewPoints, accuracy: 1)
            XCTAssertEqual(bounds.width / bounds.height, dimensions.width / dimensions.depth, accuracy: 0.01)
        }
    }
}
