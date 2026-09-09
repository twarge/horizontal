import Foundation
import HorizontalProjectIO

/// Running one of the automation channel's edit operations from the app's own
/// UI.
///
/// A few schematic objects live in the block as much as on the sheet: a bus
/// and its members, a net tie's two nets. The sheet model the canvas edits
/// carries neither half of those, and the applicator that writes a sheet back
/// can only update entries that already exist — it was never a creator. The
/// edit vocabulary behind the MCP already writes all of it the way Horizon
/// does, so the tool gathers its parameters and hands them to that, rather
/// than growing a second writer that would have to agree with the first.
///
/// What comes back is a whole archive, which is exactly what the live channel
/// already applies: the document adopts it, the project reloads, and the step
/// goes on the undo stack under the tool's own name.
enum HorizontalCanvasProjectEdit {
    /// `archive` with `operations` applied. `operations` are the same
    /// `{"op": …}` dictionaries `apply_ops` takes.
    static func archive(
        applying operations: [JSONDictionary],
        to archive: HorizontalProjectArchive,
        in project: HorizontalProject
    ) throws -> (archive: HorizontalProjectArchive, changes: [JSONDictionary]) {
        let parsed = try operations.map { try HorizontalEditOperation(json: $0) }
        let store = HorizontalArchiveFileStore(archive: archive, baseURL: project.baseURL)
        let snapshot = HorizontalDispatchSnapshot(archive: archive, baseURL: project.baseURL)
        let editor = try HorizontalProjectEditor(project: project, store: store, snapshot: snapshot)
        try editor.apply(parsed)
        _ = try editor.write()
        return (store.archive, editor.changes)
    }

    /// The message to put in front of the user when an operation is refused.
    /// The editor's errors are written for a caller who has to fix a request,
    /// which is the same thing the person driving the tool has to do.
    static func message(for error: Error) -> String {
        (error as? HorizontalDispatchError)?.message ?? error.localizedDescription
    }
}
