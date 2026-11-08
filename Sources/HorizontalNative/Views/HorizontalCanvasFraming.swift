import CoreGraphics
import Foundation

/// The transform a canvas last rendered with, kept outside SwiftUI state so
/// storing it every frame costs nothing. The live channel reads it for the
/// visible region and for framing.
@MainActor
final class HorizontalLiveCanvasTransform {
    var transform: HorizontalCanvasTransform?
}

/// The airwires a board canvas's scene was built with, and whether its
/// Connections switch lets them show. The scene is cached, so this is what
/// the canvas draws, which the board it was given need not be; the live
/// channel holds it up against what `check` reports.
struct HorizontalDrawnAirwires {
    /// Every airwire the scene was built with, the airwire filter's hidden
    /// nets' too, so it can be held up against check's.
    var airwires: [HorizontalSegment]
    /// The Connections switch.
    var shown: Bool
    /// The nets the airwire filter hides (lowercased uuids), whose airwires
    /// the canvas leaves out.
    var hiddenNetIDs: Set<String> = []

    /// The airwires the canvas draws while `shown`: those the filter lets through.
    var visibleAirwires: [HorizontalSegment] {
        guard !hiddenNetIDs.isEmpty else {
            return airwires
        }
        return airwires.filter { !hiddenNetIDs.contains($0.netID?.lowercased() ?? "") }
    }
}

/// Where the board canvas leaves `HorizontalDrawnAirwires` each time it hands
/// its scene over, kept outside SwiftUI state as the transform is.
@MainActor
final class HorizontalLiveCanvasAirwires {
    var drawn: HorizontalDrawnAirwires?
}

extension HorizontalRect {
    /// The same centre, `factor` times the size.
    func scaled(by factor: Double) -> HorizontalRect {
        let center = center
        let halfWidth = width * factor / 2
        let halfHeight = height * factor / 2
        return HorizontalRect(points: [
            HorizontalPoint(x: center.x - halfWidth, y: center.y - halfHeight),
            HorizontalPoint(x: center.x + halfWidth, y: center.y + halfHeight),
        ])
    }
}

extension CanvasViewport {
    /// The viewport that shows `rect` filling `fill` of the canvas described
    /// by `transform` (its bounds, size and insets), centered. What the live
    /// channel's zoom-to uses; the canvases apply it to their viewport binding.
    /// Its zoom and pan are measured from the transform's bounds, so a canvas
    /// showing `identity` gets them as the viewport's reference, and goes on
    /// measuring from them whatever its content does.
    static func framing(
        _ rect: HorizontalRect, in transform: HorizontalCanvasTransform, fill: CGFloat = 0.85, identity: String? = nil
    ) -> CanvasViewport {
        let bounds = transform.bounds
        guard !bounds.isEmpty, transform.size.width > 0, transform.size.height > 0 else {
            return CanvasViewport()
        }
        let target = rect.isEmpty ? HorizontalRect(center: rect.center, size: 10_000_000) : rect
        let unit = HorizontalCanvasTransform(bounds: bounds, size: transform.size, fitInsets: transform.fitInsets, zoom: 1, pan: .zero)
        let fitScale = unit.length(1)
        guard fitScale > 0 else {
            return CanvasViewport()
        }
        let insets = transform.fitInsets
        let availableWidth = max(transform.size.width - insets.leading - insets.trailing, 1) * fill
        let availableHeight = max(transform.size.height - insets.top - insets.bottom, 1) * fill
        let wanted = min(availableWidth / CGFloat(max(target.width, 1)), availableHeight / CGFloat(max(target.height, 1)))
        let zoom = min(max(wanted / fitScale, CanvasViewport.minimumZoom), CanvasViewport.maximumZoom)
        let scale = fitScale * zoom
        let center = target.center
        let fromLeft = transform.mirrored ? bounds.maxX - center.x : center.x - bounds.minX
        let pan = CGSize(
            width: CGFloat(bounds.width) * scale / 2 - CGFloat(fromLeft) * scale,
            height: CGFloat(bounds.height) * scale / 2 - CGFloat(bounds.maxY - center.y) * scale
        )
        return CanvasViewport(
            zoom: zoom, pan: pan, mirrored: transform.mirrored,
            reference: identity.map { Reference(identity: $0, bounds: bounds) }
        )
    }
}

extension CanvasViewport {
    /// The viewport that brings `rect` into view without zooming, or nil when
    /// all of it is in view already: centred on it at the scale the canvas
    /// draws at now, or at `scale` (points per world unit) when given, which
    /// is always applied. Spotlight moves a view it didn't start in this way,
    /// and a page it turns to keeps the scale the last page was seen at.
    static func revealing(
        _ rect: HorizontalRect, in transform: HorizontalCanvasTransform, scale: CGFloat? = nil, identity: String? = nil
    ) -> CanvasViewport? {
        let bounds = transform.bounds
        guard !bounds.isEmpty, transform.size.width > 0, transform.size.height > 0 else {
            return nil
        }
        if scale == nil {
            let visible = transform.visibleBounds
            if rect.minX >= visible.minX, rect.maxX <= visible.maxX, rect.minY >= visible.minY, rect.maxY <= visible.maxY {
                return nil
            }
        }
        let unit = HorizontalCanvasTransform(bounds: bounds, size: transform.size, fitInsets: transform.fitInsets, zoom: 1, pan: .zero)
        let fitScale = unit.length(1)
        let wantedScale = scale ?? transform.length(1)
        guard fitScale > 0, wantedScale > 0 else {
            return nil
        }
        let zoom = min(max(wantedScale / fitScale, CanvasViewport.minimumZoom), CanvasViewport.maximumZoom)
        let drawn = fitScale * zoom
        let center = rect.center
        let fromLeft = transform.mirrored ? bounds.maxX - center.x : center.x - bounds.minX
        let pan = CGSize(
            width: CGFloat(bounds.width) * drawn / 2 - CGFloat(fromLeft) * drawn,
            height: CGFloat(bounds.height) * drawn / 2 - CGFloat(bounds.maxY - center.y) * drawn
        )
        return CanvasViewport(
            zoom: zoom, pan: pan, mirrored: transform.mirrored,
            reference: identity.map { Reference(identity: $0, bounds: bounds) }
        )
    }
}
