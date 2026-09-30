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
    /// Delete a canvas selection as one project edit. The sheet applicator
    /// removes components when their last gate goes, but cannot remove their
    /// board packages or rebuild the other sheets' placement lists. The host
    /// reloads this archive and keeps the original archive for Undo.
    static func archive(
        deletingSelectionFrom sheet: HorizontalSchematicSheet,
        schematicURL: URL,
        to archive: HorizontalProjectArchive,
        in project: HorizontalProject
    ) throws -> HorizontalProjectArchive {
        let url = schematicURL.standardizedFileURL
        let blockSchematic = project.schematics.first { $0.schematic.url.standardizedFileURL == url }
        let schematic = blockSchematic?.schematic
            ?? (project.schematic?.url.standardizedFileURL == url ? project.schematic : nil)
        guard let schematic, let previous = schematic.sheets.first(where: { $0.id == sheet.id }) else {
            throw HorizontalDispatchError.notFound("The selected schematic sheet is no longer in the project.")
        }
        let remaining = schematic.sheets.flatMap { $0.id == sheet.id ? sheet.symbols : $0.symbols }
        let remainingComponents = Set(remaining.compactMap { $0.componentID?.lowercased() })
        let removedComponents = Set(previous.symbols.compactMap { $0.componentID?.lowercased() })
            .subtracting(remainingComponents)
        var edited = archive
        // Remove footprints before the sheet writer removes the component
        // records needed to resolve them. Existing routing keeps junctions at
        // the former pad positions, just as a board-side deletion does.
        if blockSchematic?.block.isTop != false, project.board != nil, !removedComponents.isEmpty {
            edited = try self.archive(
                applying: removedComponents.sorted().map { ["op": "remove_placement", "component": $0] },
                to: edited,
                in: project
            ).archive
        }
        try HorizontalProjectJSONApplicator.apply(
            schematicSheet: sheet, schematicURL: schematicURL, in: project, to: &edited
        )
        return edited
    }

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
