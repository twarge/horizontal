import Foundation

/// What a board layer view preset changes in a window: the layers shown,
/// whether the board is seen from below (mirrored), and the layer the
/// drawing tools are on. One rule for the live channel's `show_layers`,
/// voice, the ⌘1/⌘2 view keys and View ▸ Flip Board View (F), so all of them
/// turn the board over the same way.
struct HorizontalBoardViewState: Equatable {
    var displayOptions: BoardDisplayOptions
    var mirrored: Bool
    var drawingLayer: Int

    /// The side that is up: the one whose layers show, or, with both or
    /// neither showing, the one the view is seen from.
    var sideUp: HorizontalBoardSide {
        displayOptions.visibleSide ?? (mirrored ? .bottom : .top)
    }

    /// The view after `preset`: a side-less one ("show silkscreen") takes
    /// the side that is up, the flip the other side's placement view, seen
    /// from that side; the view presets also put the tools on that side's
    /// copper, or its silkscreen for a silkscreen view.
    mutating func apply(_ preset: HorizontalBoardLayerPreset) {
        let resolved = preset.resolved(for: sideUp)
        displayOptions.applyLayerPreset(resolved)
        if let mirrors = resolved.mirrorsView {
            mirrored = mirrors
        }
        if let layer = resolved.drawingLayer {
            drawingLayer = layer
        }
    }

    /// Turns the board over: the other side's placement view, mirrored when
    /// that side is the bottom (Horizon's Flip view).
    mutating func flip() {
        apply(.flipView)
    }
}
