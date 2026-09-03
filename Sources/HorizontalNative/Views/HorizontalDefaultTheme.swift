import SwiftUI

enum HorizontalDefaultTheme {
    static let junction = color(red: 0, green: 1, blue: 0)
    static let textOverlay = color(red: 1, green: 1, blue: 1)
    static let hole = color(red: 1, green: 1, blue: 1)
    static let dimension = color(red: 1, green: 1, blue: 1)
    static let error = color(red: 1, green: 0, blue: 0)
    static let net = color(red: 0, green: 1, blue: 0)
    static let bus = color(red: 1, green: 0.4, blue: 0)
    static let frame = color(red: 0, green: 0.5, blue: 0)
    static let airwire = color(red: 0, green: 1, blue: 1)
    static let pin = color(red: 1, green: 1, blue: 1)
    static let hiddenPin = color(red: 0.5, green: 0.5, blue: 0.5)
    static let symbolBoundingBox = color(red: 0.5, green: 0.5, blue: 0.5)
    static let diffPair = color(red: 0.5, green: 1, blue: 0)
    static let background = color(red: 0, green: 24.0 / 255.0, blue: 64.0 / 255.0)
    static let grid = color(red: 0, green: 78.0 / 255.0, blue: 208.0 / 255.0)
    static let origin = color(red: 0, green: 1, blue: 0)
    static let connectionLine = color(red: 0.7, green: 0, blue: 0.6)
    static let noPopulate = color(red: 0.8, green: 0.4, blue: 0.4)
    static let projection = color(red: 0.7, green: 0.8, blue: 0.3)
    static let netTie = color(red: 1, green: 0.1, blue: 0.5)
    static let selectableOuter = color(red: 1, green: 0, blue: 1)
    static let selectableInner = color(red: 0, green: 0, blue: 0)
    static let selectablePrelight = color(red: 0.5, green: 0, blue: 0.5)
    static let overlayBackground = background.opacity(0.78)

    static let backgroundNS = platformColor(red: 0, green: 24.0 / 255.0, blue: 64.0 / 255.0)
    static let textOverlayNS = platformColor(red: 1, green: 1, blue: 1)
    static let holeNS = platformColor(red: 1, green: 1, blue: 1)
    static let airwireNS = platformColor(red: 0, green: 1, blue: 1)
    static let connectionLineNS = platformColor(red: 0.7, green: 0, blue: 0.6)

    static func layerColor(for layer: Int?) -> Color {
        guard let layer else {
            return textOverlay
        }

        if let color = fixedLayerColors[layer] {
            return color
        }
        if HorizontalBoardLayers.isCopper(layer), layer != HorizontalBoardLayers.topCopper, layer != HorizontalBoardLayers.bottomCopper {
            return color(red: 1, green: 1, blue: 0)
        }
        if HorizontalBoardLayers.isUser(layer) {
            return color(red: 0.25, green: 1, blue: 1)
        }
        return textOverlay
    }

    static func nsLayerColor(for layer: Int?) -> HorizontalPlatformColor {
        guard let layer else {
            return textOverlayNS
        }

        if let color = fixedLayerNSColors[layer] {
            return color
        }
        if HorizontalBoardLayers.isCopper(layer), layer != HorizontalBoardLayers.topCopper, layer != HorizontalBoardLayers.bottomCopper {
            return platformColor(red: 1, green: 1, blue: 0)
        }
        if HorizontalBoardLayers.isUser(layer) {
            return platformColor(red: 0.25, green: 1, blue: 1)
        }
        return textOverlayNS
    }

    private static let fixedLayerColors: [Int: Color] = [
        HorizontalBoardLayers.topNotes: color(red: 1, green: 1, blue: 1),
        HorizontalBoardLayers.outlineNotes: color(red: 0.6, green: 0.6, blue: 0),
        HorizontalBoardLayers.outline: color(red: 0.6, green: 0.6, blue: 0),
        HorizontalBoardLayers.topCourtyard: color(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.topAssembly: color(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.topPackage: color(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.topPaste: color(red: 0.8, green: 0.8, blue: 0.8),
        HorizontalBoardLayers.topSilkscreen: color(red: 0.9, green: 0.9, blue: 0.9),
        HorizontalBoardLayers.topMask: color(red: 0.7, green: 0.3, blue: 0.9),
        HorizontalBoardLayers.topCopper: color(red: 1, green: 0, blue: 0),
        HorizontalBoardLayers.bottomCopper: color(red: 0, green: 0.5, blue: 0),
        HorizontalBoardLayers.bottomMask: color(red: 0.3, green: 0.7, blue: 1),
        HorizontalBoardLayers.bottomSilkscreen: color(red: 0.9, green: 0.9, blue: 0.9),
        HorizontalBoardLayers.bottomPaste: color(red: 0.8, green: 0.8, blue: 0.8),
        HorizontalBoardLayers.bottomPackage: color(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.bottomAssembly: color(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.bottomCourtyard: color(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.bottomNotes: color(red: 1, green: 1, blue: 1),
        HorizontalBoardLayers.dimensions: color(red: 1, green: 1, blue: 1)
    ]

    private static let fixedLayerNSColors: [Int: HorizontalPlatformColor] = [
        HorizontalBoardLayers.topNotes: platformColor(red: 1, green: 1, blue: 1),
        HorizontalBoardLayers.outlineNotes: platformColor(red: 0.6, green: 0.6, blue: 0),
        HorizontalBoardLayers.outline: platformColor(red: 0.6, green: 0.6, blue: 0),
        HorizontalBoardLayers.topCourtyard: platformColor(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.topAssembly: platformColor(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.topPackage: platformColor(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.topPaste: platformColor(red: 0.8, green: 0.8, blue: 0.8),
        HorizontalBoardLayers.topSilkscreen: platformColor(red: 0.9, green: 0.9, blue: 0.9),
        HorizontalBoardLayers.topMask: platformColor(red: 0.7, green: 0.3, blue: 0.9),
        HorizontalBoardLayers.topCopper: platformColor(red: 1, green: 0, blue: 0),
        HorizontalBoardLayers.bottomCopper: platformColor(red: 0, green: 0.5, blue: 0),
        HorizontalBoardLayers.bottomMask: platformColor(red: 0.3, green: 0.7, blue: 1),
        HorizontalBoardLayers.bottomSilkscreen: platformColor(red: 0.9, green: 0.9, blue: 0.9),
        HorizontalBoardLayers.bottomPaste: platformColor(red: 0.8, green: 0.8, blue: 0.8),
        HorizontalBoardLayers.bottomPackage: platformColor(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.bottomAssembly: platformColor(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.bottomCourtyard: platformColor(red: 0.5, green: 0.5, blue: 0.5),
        HorizontalBoardLayers.bottomNotes: platformColor(red: 1, green: 1, blue: 1),
        HorizontalBoardLayers.dimensions: platformColor(red: 1, green: 1, blue: 1)
    ]

    private static func color(red: Double, green: Double, blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }

    static func nsColor(red: Double, green: Double, blue: Double) -> HorizontalPlatformColor {
        platformColor(red: red, green: green, blue: blue)
    }

    static func platformColor(red: Double, green: Double, blue: Double) -> HorizontalPlatformColor {
        HorizontalPlatformColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }
}
