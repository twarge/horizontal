import SwiftUI

#if canImport(AppKit)
import AppKit
typealias HorizontalPlatformColor = NSColor
typealias HorizontalPlatformBezierPath = NSBezierPath
#elseif canImport(UIKit)
import UIKit
typealias HorizontalPlatformColor = UIColor
typealias HorizontalPlatformBezierPath = UIBezierPath
#endif

extension Color {
    static var horizonPlatformLabel: Color {
        #if canImport(AppKit)
        Color(nsColor: .labelColor)
        #else
        Color(uiColor: .label)
        #endif
    }

    static var horizonPlatformWindowBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

extension HorizontalPlatformBezierPath {
    func horizonLine(to point: CGPoint) {
        #if canImport(AppKit)
        line(to: point)
        #else
        addLine(to: point)
        #endif
    }

    func horizonUseEvenOddWinding() {
        #if canImport(AppKit)
        windingRule = .evenOdd
        #else
        usesEvenOddFillRule = true
        #endif
    }
}
