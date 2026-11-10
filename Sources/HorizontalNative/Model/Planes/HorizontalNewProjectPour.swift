import Foundation
import HorizontalProjectIO

extension HorizontalProjectArchive {
    /// A brand-new project as File > New, Create Document and MCP
    /// `new_project` hand it out: the template (`newProject`) with its board's
    /// planes poured, which the template can't do itself. Its GND via joins
    /// both planes to their net, so they keep their fill and a new board
    /// checks clean, where unpoured they were two "Plane has no fragments"
    /// errors. A blank board has no planes, and should the pour fail the
    /// project is the template as it is, which still opens.
    static func newPouredProject(
        named name: String = "Untitled",
        pool: HorizontalProjectPoolTemplate = HorizontalProjectPoolTemplate(),
        blankBoard: Bool = false
    ) -> HorizontalProjectArchive {
        var archive = newProject(named: name, pool: pool, blankBoard: blankBoard)
        guard !blankBoard,
              let project = try? HorizontalProject.loadSnapshot(of: archive),
              let board = project.board, !board.planes.isEmpty,
              let fills = try? HorizontalProjectJSONApplicator.planeCacheData(board: HorizontalBoardPlaneUpdater.updateAllPlanes(in: board))
        else {
            return archive
        }
        _ = try? HorizontalProjectJSONApplicator.applyPlaneCache(data: fills, in: project, to: &archive)
        return archive
    }
}
