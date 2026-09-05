import SwiftUI

enum HorizontalGridRenderer {
    /// The origin mark: the grid's cross at twice its weight with a ring
    /// around it, a fixed size on screen. Drawn by the Metal backdrop when
    /// available; this is the CoreGraphics fallback.
    static func drawOriginMark(
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        color: Color,
        markSize: CGFloat = 5,
        lineWidth: CGFloat = 0.5
    ) {
        let center = pixelAligned(transform.point(.zero))
        let arm = markSize * 1.8
        let radius = markSize * 1.2
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: max(lineWidth, 0.5) * 2, lineCap: .square)
        )
    }

    static func drawCrossGrid(
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        baseSpacing: HorizontalPoint,
        origin: HorizontalPoint = .zero,
        color: Color,
        minimumScreenSpacing: CGFloat = 20,
        markSize: CGFloat = 5,
        lineWidth: CGFloat = 0.5
    ) {
        let visible = transform.visibleBounds
        guard !visible.isEmpty, baseSpacing.x > 0, baseSpacing.y > 0 else {
            return
        }

        var spacing = baseSpacing
        while transform.length(spacing.x) < minimumScreenSpacing
            || transform.length(spacing.y) < minimumScreenSpacing {
            spacing = spacing * 2
        }

        let startX = (round((visible.minX - origin.x) / spacing.x) - 1) * spacing.x + origin.x
        let startY = (round((visible.minY - origin.y) / spacing.y) - 1) * spacing.y + origin.y
        let endX = visible.maxX + spacing.x
        let endY = visible.maxY + spacing.y

        var path = Path()
        var x = startX
        while x <= endX {
            var y = startY
            while y <= endY {
                let point = pixelAligned(transform.point(HorizontalPoint(x: x, y: y)))
                path.move(to: CGPoint(x: point.x, y: point.y - markSize))
                path.addLine(to: CGPoint(x: point.x, y: point.y + markSize))
                path.move(to: CGPoint(x: point.x - markSize, y: point.y))
                path.addLine(to: CGPoint(x: point.x + markSize, y: point.y))
                y += spacing.y
            }
            x += spacing.x
        }

        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .square)
        )
    }

    private static func pixelAligned(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.rounded() + 0.5, y: point.y.rounded() + 0.5)
    }
}
