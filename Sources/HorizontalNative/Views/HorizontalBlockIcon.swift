import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// A schematic block's icon: three isometric cubes stacked in a pyramid, a
/// block built of others. SF Symbols has a cube but no stack of them, so the
/// stack is drawn here, as a template image that menus, toolbars and labels
/// tint as they tint a symbol.
enum HorizontalBlockIcon {
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

    /// The cubes in `rect`, y down: the two below first, then the one on
    /// top, which clears what it hides — and a hairline round it, so it
    /// stands off the others — before its edges are stroked.
    static func draw(in rect: CGRect, context: CGContext, lineWidth: CGFloat = 1.2, gap: CGFloat = 0.6) {
        let c30 = cos(CGFloat.pi / 6)
        let edge = min((rect.width - lineWidth) / (4 * c30), (rect.height - lineWidth) / 3)
        // The lower cubes' centres sit on this line, the top cube's one edge up.
        let origin = CGPoint(x: rect.midX, y: rect.midY + edge / 2)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineJoin(.round)
        context.setLineCap(.round)

        func cube(_ dx: CGFloat, _ dy: CGFloat, knocksOut: Bool) {
            let centre = CGPoint(x: origin.x + dx * edge, y: origin.y + dy * edge)
            let top = CGPoint(x: centre.x, y: centre.y - edge)
            let upperRight = CGPoint(x: centre.x + c30 * edge, y: centre.y - edge / 2)
            let lowerRight = CGPoint(x: centre.x + c30 * edge, y: centre.y + edge / 2)
            let bottom = CGPoint(x: centre.x, y: centre.y + edge)
            let lowerLeft = CGPoint(x: centre.x - c30 * edge, y: centre.y + edge / 2)
            let upperLeft = CGPoint(x: centre.x - c30 * edge, y: centre.y - edge / 2)
            let outline = CGMutablePath()
            outline.addLines(between: [top, upperRight, lowerRight, bottom, lowerLeft, upperLeft])
            outline.closeSubpath()
            if knocksOut {
                context.saveGState()
                context.setBlendMode(.clear)
                context.addPath(outline)
                context.fillPath()
                context.addPath(outline)
                context.setLineWidth(lineWidth + gap * 2)
                context.strokePath()
                context.restoreGState()
            }
            let edges = CGMutablePath()
            edges.addPath(outline)
            edges.addLines(between: [upperLeft, centre, upperRight])
            edges.addLines(between: [centre, bottom])
            context.addPath(edges)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }
        // The two below touch along an edge and hide nothing of each other.
        cube(-c30, 0, knocksOut: false)
        cube(c30, 0, knocksOut: false)
        cube(0, -1, knocksOut: true)
    }
}

/// The block icon in a row of symbols, as big as a symbol would be at the
/// row's font, so it lines up with them.
struct HorizontalBlockIconView: View {
    var body: some View {
        Image(systemName: "square.stack.3d.up")
            .hidden()
            .overlay {
                HorizontalBlockIcon.image
                    .resizable()
                    .scaledToFit()
            }
            .accessibilityLabel("Block")
    }
}
