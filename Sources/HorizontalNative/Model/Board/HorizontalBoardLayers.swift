import Foundation

enum HorizontalBoardLayerCategory {
    case topCopper
    case innerCopper
    case bottomCopper
    case silkscreen
    case solderMask
    case paste
    case outline
    case user
    case fabrication
    case other
}

enum HorizontalBoardLayers {
    static let lastUserLayer = 1007
    static let firstUserLayer = 1000
    static let user1 = firstUserLayer + 0
    static let user2 = firstUserLayer + 1
    static let user3 = firstUserLayer + 2
    static let user4 = firstUserLayer + 3
    static let user5 = firstUserLayer + 4
    static let user6 = firstUserLayer + 5
    static let user7 = firstUserLayer + 6
    static let user8 = firstUserLayer + 7
    static let topNotes = 200
    static let outlineNotes = 110
    static let outline = 100
    static let topCourtyard = 60
    static let topAssembly = 50
    static let topPackage = 40
    static let topPaste = 30
    static let topSilkscreen = 20
    static let topMask = 10
    static let topCopper = 0
    static let in1Copper = -1
    static let in2Copper = -2
    static let in3Copper = -3
    static let in4Copper = -4
    static let in5Copper = -5
    static let in6Copper = -6
    static let in7Copper = -7
    static let in8Copper = -8
    static let bottomCopper = -100
    static let bottomMask = -110
    static let bottomSilkscreen = -120
    static let bottomPaste = -130
    static let bottomPackage = -140
    static let bottomAssembly = -150
    static let bottomCourtyard = -160
    static let bottomNotes = -200
    static let dimensions = 10000

    static let maxUserLayers = lastUserLayer - firstUserLayer + 1
    static let maxInnerLayers = 8
    static let layerRangeThrough = (start: topCopper, end: bottomCopper)

    static let all = [
        topNotes,
        outlineNotes,
        outline,
        topCourtyard,
        topAssembly,
        topPackage,
        topPaste,
        topSilkscreen,
        topMask,
        topCopper,
        in1Copper,
        in2Copper,
        in3Copper,
        in4Copper,
        in5Copper,
        in6Copper,
        in7Copper,
        in8Copper,
        bottomCopper,
        bottomMask,
        bottomSilkscreen,
        bottomPaste,
        bottomPackage,
        bottomAssembly,
        bottomCourtyard,
        bottomNotes,
        user1,
        user2,
        user3,
        user4,
        user5,
        user6,
        user7,
        user8
    ]

    static func isCopper(_ layer: Int) -> Bool {
        layer <= topCopper && layer >= bottomCopper
    }

    static func isSilkscreen(_ layer: Int) -> Bool {
        layer == topSilkscreen || layer == bottomSilkscreen
    }

    static func isUser(_ layer: Int) -> Bool {
        layer <= lastUserLayer && layer >= firstUserLayer
    }

    static func isOutline(_ layer: Int) -> Bool {
        layer == outline || layer == outlineNotes
    }

    static func isBottomSide(_ layer: Int) -> Bool {
        layer <= bottomCopper
    }

    static func name(for layer: Int) -> String {
        switch layer {
        case topNotes:
            return "Top Notes"
        case outlineNotes:
            return "Outline Notes"
        case outline:
            return "Outline"
        case topCourtyard:
            return "Top Courtyard"
        case topAssembly:
            return "Top Assembly"
        case topPackage:
            return "Top Package"
        case topPaste:
            return "Top Paste"
        case topSilkscreen:
            return "Top Silkscreen"
        case topMask:
            return "Top Mask"
        case topCopper:
            return "Top Copper"
        case in8Copper...in1Copper:
            return "Inner \(-layer)"
        case bottomCopper:
            return "Bottom Copper"
        case bottomMask:
            return "Bottom Mask"
        case bottomSilkscreen:
            return "Bottom Silkscreen"
        case bottomPaste:
            return "Bottom Paste"
        case bottomPackage:
            return "Bottom Package"
        case bottomAssembly:
            return "Bottom Assembly"
        case bottomCourtyard:
            return "Bottom Courtyard"
        case bottomNotes:
            return "Bottom Notes"
        case dimensions:
            return "Dimensions"
        case firstUserLayer...lastUserLayer:
            return "User \(layer - firstUserLayer + 1)"
        default:
            return "Invalid layer \(layer)"
        }
    }

    static func category(for layer: Int) -> HorizontalBoardLayerCategory {
        if layer == topCopper {
            return .topCopper
        }
        if layer < topCopper && layer > bottomCopper {
            return .innerCopper
        }
        if layer == bottomCopper {
            return .bottomCopper
        }
        if isSilkscreen(layer) {
            return .silkscreen
        }
        if layer == topMask || layer == bottomMask {
            return .solderMask
        }
        if layer == topPaste || layer == bottomPaste {
            return .paste
        }
        if isOutline(layer) {
            return .outline
        }
        if isUser(layer) {
            return .user
        }
        if (bottomNotes...topNotes).contains(layer) {
            return .fabrication
        }
        return .other
    }

    static func flippedPackageLayer(_ layer: Int, nInnerLayers: Int) -> Int {
        if layer == outline {
            return layer
        }
        if layer < topCopper && layer > bottomCopper {
            guard nInnerLayers > 0 else {
                return layer
            }
            return -layer - (nInnerLayers + 1)
        }
        return -layer - 100
    }

    static func packageLayer(_ layer: Int?, flipped: Bool, nInnerLayers: Int) -> Int? {
        guard let layer else {
            return nil
        }
        return flipped ? flippedPackageLayer(layer, nInnerLayers: nInnerLayers) : layer
    }
}
