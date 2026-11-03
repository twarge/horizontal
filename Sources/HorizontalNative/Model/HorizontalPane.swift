import SwiftUI

enum HorizontalPane: String, CaseIterable, Codable, Identifiable {
    case library
    case parts
    case schematic
    case board
    case threeD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parts: "Parts"
        case .library: "Pools"
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

    /// A canvas pane: one with canvas commands (select, copy, rotate…) and a
    /// view to zoom. The Pools and Parts panes are lists; with the keyboard,
    /// they take its keys for themselves.
    var hasCanvas: Bool {
        switch self {
        case .schematic, .board, .threeD: true
        case .parts, .library: false
        }
    }

    /// The pane Tab on this one goes to: the board from the schematic and
    /// the schematic from the board. The other panes have none.
    var tabCounterpart: HorizontalPane? {
        switch self {
        case .schematic: .board
        case .board: .schematic
        case .parts, .library, .threeD: nil
        }
    }

    /// The panes open after Tab on `self` goes to `tabCounterpart`: as they
    /// are when it is open too, since Tab then only moves the keyboard;
    /// otherwise with it in this one's place, beside the rest.
    func panesAfterTab(from visiblePanes: Set<HorizontalPane>) -> Set<HorizontalPane> {
        guard let other = tabCounterpart, !visiblePanes.contains(other) else {
            return visiblePanes
        }
        var panes = visiblePanes
        panes.remove(self)
        panes.insert(other)
        return panes
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
