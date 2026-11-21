import CoreGraphics
import CoreText
import Foundation

/// What render_board can draw over the board so a picture can be read as
/// numbers: a millimetre grid with its axes labelled, items picked out, and
/// shapes that are not on the board yet.
struct HorizontalRenderAnnotations {
    /// The grid's pitch in millimetres; nil for none.
    var gridMM: Double?
    var highlight: [HorizontalBoardItem.Shape] = []
    var overlay: [HorizontalBoardItem.Shape] = []
    /// The part of the board the picture shows; nil for all of it.
    var region: HorizontalRect?

    var isEmpty: Bool { gridMM == nil && highlight.isEmpty && overlay.isEmpty }

    static let highlightColor: [CGFloat] = [0.95, 0, 0.75, 0.75]
    static let overlayColor: [CGFloat] = [1, 0.5, 0, 0.8]
    static let gridColor: [CGFloat] = [0.1, 0.1, 0.1, 0.35]

    func draw(in context: CGContext, mapping: HorizontalDispatchRender.PageMapping, pixelsPerPoint: CGFloat) {
        let pixel = 1 / max(pixelsPerPoint, 0.01)
        let content = mapping.content
        // The mapping puts a point where the drawing has it, turned over
        // about the board's middle when the drawing is mirrored.
        let mirrored = mapping.mirrored
        let place = mapping.point
        func color(_ components: [CGFloat]) -> CGColor {
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: components) ?? CGColor(gray: 0, alpha: 1)
        }
        func fill(_ shapes: [HorizontalBoardItem.Shape], _ components: [CGFloat]) {
            context.saveGState()
            context.setFillColor(color(components))
            context.setStrokeColor(color(components))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for shape in shapes {
                switch shape {
                case .path(let points, let halfWidth):
                    guard let first = points.first else { continue }
                    context.setLineWidth(max(CGFloat(halfWidth * 2) * mapping.scale, 2 * pixel))
                    context.move(to: place(first))
                    for point in points.dropFirst() { context.addLine(to: place(point)) }
                    if points.count == 1 { context.addLine(to: place(first)) }
                    context.strokePath()
                case .disc(let center, let radius):
                    let at = place(center), r = max(CGFloat(radius) * mapping.scale, 2 * pixel)
                    context.fillEllipse(in: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r))
                case .polygon(let points):
                    guard let first = points.first else { continue }
                    context.move(to: place(first))
                    for point in points.dropFirst() { context.addLine(to: place(point)) }
                    context.closePath()
                    context.fillPath()
                case .region(let paths):
                    for path in paths {
                        guard let first = path.first else { continue }
                        context.move(to: place(first))
                        for point in path.dropFirst() { context.addLine(to: place(point)) }
                        context.closePath()
                    }
                    context.fillPath(using: .evenOdd)
                }
            }
            context.restoreGState()
        }
        fill(highlight, Self.highlightColor)
        fill(overlay, Self.overlayColor)

        guard let gridMM, gridMM > 0 else { return }
        let shown = region ?? content
        // No more than about forty lines either way, so the labels can be read.
        var pitch = gridMM * 1_000_000
        for factor in [1.0, 2, 5, 10, 20, 50, 100, 200, 500, 1000] where max(shown.width, shown.height) / (gridMM * 1_000_000 * factor) <= 40 {
            pitch = gridMM * 1_000_000 * factor
            break
        }
        context.saveGState()
        context.setStrokeColor(color(Self.gridColor))
        context.setLineWidth(pixel)
        let font = CTFontCreateWithName("Helvetica" as CFString, 10 * pixel, nil)
        func label(_ value: Double, at point: CGPoint) {
            let text = value.rounded() == value ? String(Int(value)) : String(format: "%g", (value * 1000).rounded() / 1000)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color([0, 0, 0, 0.85])] as CFDictionary
            guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return }
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        // Labels sit just inside the picture's left and bottom edges, in
        // board millimetres whichever way the board is turned.
        let low = place(HorizontalPoint(x: mirrored ? shown.maxX : shown.minX, y: shown.minY))
        let high = place(HorizontalPoint(x: mirrored ? shown.minX : shown.maxX, y: shown.maxY))
        var x = (shown.minX / pitch).rounded(.up) * pitch
        while x <= shown.maxX {
            let at = place(HorizontalPoint(x: x, y: shown.minY))
            context.move(to: CGPoint(x: at.x, y: low.y))
            context.addLine(to: CGPoint(x: at.x, y: high.y))
            context.strokePath()
            label(x / 1_000_000, at: CGPoint(x: at.x + 2 * pixel, y: low.y + 2 * pixel))
            x += pitch
        }
        var y = (shown.minY / pitch).rounded(.up) * pitch
        while y <= shown.maxY {
            let at = place(HorizontalPoint(x: shown.minX, y: y))
            context.move(to: CGPoint(x: low.x, y: at.y))
            context.addLine(to: CGPoint(x: high.x, y: at.y))
            context.strokePath()
            label(y / 1_000_000, at: CGPoint(x: low.x + 2 * pixel, y: at.y + 2 * pixel))
            y += pitch
        }
        context.restoreGState()
    }
}
