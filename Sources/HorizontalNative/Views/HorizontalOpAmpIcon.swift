import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// An op-amp: a triangle pointing right, its + and − inputs on the left and
/// its output at the tip — what a block's symbol stands in for on the sheets
/// that use it. SF Symbols has none, so it is drawn here, as a template image
/// that menus, toolbars and labels tint as they tint a symbol.
enum HorizontalOpAmpIcon {
    /// The image's size in points, about a symbol's at body size.
    static let size = CGSize(width: 18, height: 16)

    static var image: Image {
        #if canImport(AppKit)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: rect, context: context)
            return true
        }
        image.isTemplate = true
        return Image(nsImage: image)
        #else
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            draw(in: CGRect(origin: .zero, size: size), context: renderer.cgContext)
        }
        return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
        #endif
    }

    /// The op-amp in `rect`, y down, laid out on an 18 × 16 grid.
    static func draw(in rect: CGRect, context: CGContext, lineWidth: CGFloat = 1.2) {
        let sx = rect.width / size.width, sy = rect.height / size.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let body = CGMutablePath()
        body.addLines(between: [point(4.5, 1), point(15.5, 8), point(4.5, 15)])
        body.closeSubpath()
        body.addLines(between: [point(0.8, 5), point(4.5, 5)])
        body.addLines(between: [point(0.8, 11), point(4.5, 11)])
        body.addLines(between: [point(15.5, 8), point(17.4, 8)])
        context.addPath(body)
        context.setLineWidth(lineWidth)
        context.strokePath()

        // The signs a little lighter, so they stay clear of the edges.
        let arm: CGFloat = 1.05
        let signs = CGMutablePath()
        signs.addLines(between: [point(6.8 - arm, 5), point(6.8 + arm, 5)])
        signs.addLines(between: [point(6.8, 5 - arm), point(6.8, 5 + arm)])
        signs.addLines(between: [point(6.8 - arm, 11), point(6.8 + arm, 11)])
        context.addPath(signs)
        context.setLineWidth(lineWidth * 0.75)
        context.strokePath()
    }
}

/// The op-amp in a row of symbols, as big as a symbol would be at the row's
/// font, so it lines up with them.
struct HorizontalOpAmpIconView: View {
    var body: some View {
        Image(systemName: "square.on.square.dashed")
            .hidden()
            .overlay {
                HorizontalOpAmpIcon.image
                    .resizable()
                    .scaledToFit()
            }
            .accessibilityLabel("Symbol")
    }
}
