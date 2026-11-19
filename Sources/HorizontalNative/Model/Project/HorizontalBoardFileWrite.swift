import Foundation
#if canImport(HorizontalProjectIO)
import HorizontalProjectIO
#endif

/// A board commit and the board's file. What is on screen is the board
/// model, current the moment an edit commits; the file's bytes are wanted
/// only when the document's archive is read: by a save, an export, a
/// schematic or rules edit, the automation channel. So a commit hands the
/// document its board and returns, and the file is written from the latest
/// board behind it, or at once when something reads the archive first. A
/// board that another commit follows before anything read it is never
/// written.
enum HorizontalBoardFileWrite {
    /// Off with `HORIZONTAL_EAGER_BOARD_WRITES` in the environment, which
    /// writes the file in the commit as before: for timing one against the
    /// other, and for ruling the deferral out when a file looks wrong.
    static let isDeferred = ProcessInfo.processInfo.environment["HORIZONTAL_EAGER_BOARD_WRITES"] == nil
}

extension HorizontalProjectDocument {
    /// Leaves `board` to be written into the board's file when the archive
    /// is next read. The file is patched from the board as a whole, so this
    /// takes the place of a board left before it and not yet written.
    mutating func deferBoardWrite(_ board: HorizontalBoard, in project: HorizontalProject) {
        deferArchiveEdit { archive in
            _ = try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        }
    }
}
