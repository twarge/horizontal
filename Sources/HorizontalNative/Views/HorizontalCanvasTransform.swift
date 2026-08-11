import CoreGraphics
import Foundation

struct HorizontalCanvasInsets: Equatable {
    static let defaultFit = HorizontalCanvasInsets(top: 32, leading: 32, bottom: 32, trailing: 32)
    static let fullBleedMinimumFit = HorizontalCanvasInsets(top: 80, leading: 32, bottom: 32, trailing: 32)

    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat
}

struct HorizontalCanvasTransform {
    var bounds: HorizontalRect
    var size: CGSize
    var fitInsets: HorizontalCanvasInsets = .defaultFit
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var minimumLineWidth: CGFloat = 0

    private var fitScale: CGFloat {
        guard !bounds.isEmpty else {
            return 1
        }

        let availableWidth = max(size.width - fitInsets.leading - fitInsets.trailing, 1)
        let availableHeight = max(size.height - fitInsets.top - fitInsets.bottom, 1)
        return min(availableWidth / bounds.width, availableHeight / bounds.height)
    }

    private var scale: CGFloat {
        fitScale * max(zoom, 0.01)
    }

    private var origin: CGPoint {
        guard !bounds.isEmpty else {
            return CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        }

        let contentWidth = bounds.width * scale
        let contentHeight = bounds.height * scale
        return CGPoint(
            x: (size.width - contentWidth) / 2 + pan.width,
            y: (size.height - contentHeight) / 2 + pan.height
        )
    }

    func point(_ point: HorizontalPoint) -> CGPoint {
        let origin = origin
        let x = origin.x + (point.x - bounds.minX) * scale
        let y = origin.y + (bounds.maxY - point.y) * scale
        return CGPoint(x: x, y: y)
    }

    func worldPoint(_ point: CGPoint) -> HorizontalPoint {
        guard !bounds.isEmpty else {
            return .zero
        }

        let origin = origin
        return HorizontalPoint(
            x: bounds.minX + Double((point.x - origin.x) / scale),
            y: bounds.maxY - Double((point.y - origin.y) / scale)
        )
    }

    var visibleBounds: HorizontalRect {
        HorizontalRect(points: [
            worldPoint(CGPoint(x: 0, y: 0)),
            worldPoint(CGPoint(x: size.width, y: 0)),
            worldPoint(CGPoint(x: 0, y: size.height)),
            worldPoint(CGPoint(x: size.width, y: size.height))
        ])
    }

    func length(_ value: Double) -> CGFloat {
        max(CGFloat(value) * scale, 0)
    }

    var worldUnitsPerPoint: Double {
        guard scale > 0 else {
            return 0
        }
        return 1 / Double(scale)
    }

    func strokeWidth(_ value: Double, minimum: CGFloat = 1) -> CGFloat {
        max(length(value), minimum, minimumLineWidth)
    }
}
