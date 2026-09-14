import CoreGraphics
import Foundation

/// The transform a canvas last rendered with, kept outside SwiftUI state so
/// storing it every frame costs nothing. The live channel reads it for the
/// visible region and for framing.
@MainActor
final class HorizontalLiveCanvasTransform {
    var transform: HorizontalCanvasTransform?
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
    static func framing(_ rect: HorizontalRect, in transform: HorizontalCanvasTransform, fill: CGFloat = 0.85) -> CanvasViewport {
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
        return CanvasViewport(zoom: zoom, pan: pan, mirrored: transform.mirrored)
    }
}
