import Foundation

/// Where the workspace's selection was made: the last one made, which every
/// view boxes in blue and Spotlight (L) spotlights. A schematic page change
/// drops the schematic canvas's own selection, which is of the objects on the
/// page it leaves, and the workspace's selection goes with it only when that
/// is the one it was showing. A selection made on the board, in the 3D view,
/// by Find, in the Parts pane or over the live channel is still selected
/// where it was made, so it stays through the page change: boxed on the page
/// turned to, and what the View menu's Spotlight spotlights.
struct HorizontalSelectionOrigin: Equatable {
    /// The canvas it was made in: the schematic or the board. Nil for one
    /// made anywhere else, which both canvases were asked to show.
    var pane: HorizontalPane?
    /// The window that canvas is in, where a project has several: one
    /// window's schematic turning its page leaves alone what another
    /// window's schematic selected. Nil where there is one window.
    var window: UUID?

    /// Whether the schematic in `window` turning its page takes the
    /// selection with it: only when that schematic made it.
    func goesWithSchematicPage(in window: UUID? = nil) -> Bool {
        pane == .schematic && self.window == window
    }
}
