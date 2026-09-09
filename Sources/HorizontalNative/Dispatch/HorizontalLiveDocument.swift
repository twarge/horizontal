import Foundation
import HorizontalProjectIO

/// What a live edit replaces and what undo restores.
struct HorizontalLiveSnapshot {
    var archive: HorizontalProjectArchive
    var project: HorizontalProject
}

struct HorizontalLiveSelection {
    var netIDs: Set<String> = []
    var componentIDs: Set<String> = []
    var highlightedNetIDs: Set<String> = []
    var highlightedComponentIDs: Set<String> = []
    var panes: [String] = []
}

/// What a document open in the app exposes to the dispatch layer: its
/// current model, its archive for edits, its selection, and the hooks that
/// change what the user sees. The workspace view fills the closures in when
/// it appears and registers the document with the dispatch session.
@MainActor
final class HorizontalLiveDocument {
    let url: URL
    var title: String
    var currentProject: () -> HorizontalProject
    var revision: () -> String
    var archive: () -> HorizontalProjectArchive
    var isReadOnly: () -> Bool
    var selection: () -> HorizontalLiveSelection
    /// Net ids and component ids to highlight; empty sets clear.
    var setHighlight: (Set<String>, Set<String>) -> Void
    var setSelection: (Set<String>, Set<String>) -> Void
    /// Swaps in an edited archive as one undoable step named `actionName`.
    var applyArchive: (HorizontalProjectArchive, String) throws -> Void
    /// Whether the document has changes its file does not have yet.
    var isEdited: () -> Bool
    /// What Undo would take back, and what Redo would put back — the action
    /// names the app shows in its Edit menu, or nil when there is nothing.
    var undoActionName: () -> String?
    var redoActionName: () -> String?
    /// Takes back the last step on the document's undo stack, or puts one back.
    /// Returns what it did, or nil when there was nothing to do.
    var undo: () -> String?
    var redo: () -> String?
    /// Writes the document to its file, the way the Save command does. An edit
    /// made through this channel is one undoable step in an open document and
    /// nothing more until this runs.
    var save: () throws -> Void
    /// The world rectangle a pane's canvas shows, if the pane is up.
    var visibleBounds: (HorizontalPane) -> HorizontalRect?
    /// Frames a world rectangle in a pane's canvas, showing the pane first.
    var frame: (HorizontalPane, HorizontalRect) -> Void
    /// Shows a sheet (block id, sheet id) in the schematic pane.
    var showSheet: (String?, String) -> Void
    /// The sheet the schematic pane shows, if any.
    var currentSheet: () -> String?

    init(url: URL, title: String, project: HorizontalProject, archive: HorizontalProjectArchive) {
        self.url = url
        self.title = title
        currentProject = { project }
        revision = { "0" }
        self.archive = { archive }
        isReadOnly = { false }
        selection = { HorizontalLiveSelection() }
        setHighlight = { _, _ in }
        setSelection = { _, _ in }
        applyArchive = { _, _ in
            throw HorizontalDispatchError.failed("This document does not accept edits.")
        }
        isEdited = { false }
        undoActionName = { nil }
        redoActionName = { nil }
        undo = { nil }
        redo = { nil }
        save = {
            throw HorizontalDispatchError.failed("This document does not know how to save itself.")
        }
        visibleBounds = { _ in nil }
        frame = { _, _ in }
        showSheet = { _, _ in }
        currentSheet = { nil }
    }
}
