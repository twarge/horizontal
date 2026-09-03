import SwiftUI

enum HorizontalPane: String, CaseIterable, Codable, Identifiable {
    case parts
    case library
    case schematic
    case board
    case threeD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parts: "Parts"
        case .library: "Library"
        case .schematic: "Schematic"
        case .board: "Board"
        case .threeD: "3D Board"
        }
    }

    var symbolName: String {
        switch self {
        case .parts: "list.bullet.rectangle"
        case .library: "books.vertical"
        case .schematic: "point.3.connected.trianglepath.dotted"
        case .board: "cpu"
        case .threeD: "cube"
        }
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .parts: "1"
        case .library: "5"
        case .schematic: "2"
        case .board: "3"
        case .threeD: "4"
        }
    }
}
