import SwiftUI

/// Resolves how a board layer is drawn in Metal: its color, its per-layer
/// composite group, whether it's filled, and (for vias) which copper layers a
/// marker spans. Extracted from `BoardCanvasView` so the metal batch builder can
/// be driven by an explicit, testable value instead of reaching into View state
/// (theme / display options / user layers).
///
/// `colorsByLayer` is a snapshot resolved once from the theme + user layers;
/// `compositeGroup` and `renderedViaLayers` are pure.
struct BoardLayerStyle {
    /// Per-layer colors, pre-resolved from the theme/user layers.
    let colorsByLayer: [Int: Color]
    /// Color for geometry with no (or an unknown) layer.
    let fallbackColor: Color
    /// Display options, consulted for fill state.
    let displayOptions: BoardDisplayOptions

    /// Layers are mapped to distinct composite groups by a fixed offset so each
    /// renders into its own per-layer opacity texture. Must stay >0 (group 0 is
    /// the non-composited main pass).
    static let compositeGroupOffset = 1_000_000

    /// Metal color for a layer, scaled by `opacity` (applied to the SwiftUI Color
    /// before conversion, matching the former `layerMetalColor`).
    func metalColor(for layer: Int?, opacity: Double = 1) -> HorizontalMetalRGBA {
        HorizontalMetalRGBA((layer.flatMap { colorsByLayer[$0] } ?? fallbackColor).opacity(opacity))
    }

    func isFilled(_ layer: Int?) -> Bool {
        displayOptions.isLayerFilled(layer)
    }

    func compositeGroup(for layer: Int) -> Int {
        Self.compositeGroup(for: layer)
    }

    static func compositeGroup(for layer: Int) -> Int {
        compositeGroupOffset + layer
    }

    /// The copper layers a via spans (its explicit connected layers, or its own
    /// layer / top copper as a fallback), copper-only and sorted.
    static func renderedViaLayers(for via: HorizontalMarker) -> [Int] {
        let layers = via.connectedLayers.isEmpty
            ? [via.layer ?? HorizontalBoardLayers.topCopper]
            : via.connectedLayers
        return layers
            .filter { HorizontalBoardLayers.isCopper($0) }
            .sorted()
    }
}
