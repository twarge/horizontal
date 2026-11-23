import SwiftUI

/// A pin as a canvas found it under the pointer, with the functions its
/// alternates offer: the schematic's from the symbol it drew, the board's
/// from the pad's part.
struct HorizontalPinFunctionTarget: Equatable {
    /// The component as the canvas names it.
    var componentID: String
    var gateID: String
    var pinID: String
    var pinName: String
    var functions: [String]

    var gatePinPath: String { "\(gateID)/\(pinID)" }
}

/// What a project window gives its canvases for the pin Spotlight: the one
/// showing, and how to show one, end it, and move the function's net to a
/// pin that is free.
struct HorizontalPinSpotlightActions {
    var spotlight: HorizontalPinFunctionSpotlight?
    /// False where the document can't be edited: the Spotlight shows, and
    /// a click on a free pin moves nothing.
    var canMove: Bool
    /// Component (as the canvas names it), the gate/pin asked from, function.
    var show: (String, String?, String) -> Void
    var clear: () -> Void
    var move: (HorizontalPinFunctionSpotlight.Pin) -> Void
    /// The pin a pad of a board component is, and what it offers.
    var padTarget: (_ componentID: String, _ padID: String) -> HorizontalPinFunctionTarget?
}

private struct HorizontalPinSpotlightActionsKey: EnvironmentKey {
    static var defaultValue: HorizontalPinSpotlightActions? { nil }
}

extension EnvironmentValues {
    var horizonPinSpotlight: HorizontalPinSpotlightActions? {
        get { self[HorizontalPinSpotlightActionsKey.self] }
        set { self[HorizontalPinSpotlightActionsKey.self] = newValue }
    }
}

/// The right-click menu's entries for a pin, on the schematic and, for its
/// pad, on the board: Spotlight every pin of the component that offers one
/// of the pin's functions, and, while such a Spotlight shows and the pin is
/// one of its free ones, move the function here.
enum HorizontalPinFunctionMenu {
    static func spotlightTitle(_ function: String) -> String { "Spotlight Pins Offering \(function)" }
    static func moveTitle(_ function: String, to pinName: String) -> String { "Move \(function) to \(pinName)" }

    static func entries(
        for target: HorizontalPinFunctionTarget?,
        actions: HorizontalPinSpotlightActions?
    ) -> [HorizontalTargetItemMenuEntry] {
        guard let target, let actions else {
            return []
        }
        var entries = [HorizontalTargetItemMenuEntry]()
        if let pin = movable(target, actions: actions), let spotlight = actions.spotlight {
            entries.append(.command(title: moveTitle(spotlight.function, to: pin.name),
                                    .movePinFunctionNet(gate: pin.gateID, pin: pin.pinID)))
        }
        func command(_ function: String, title: String) -> HorizontalTargetItemMenuEntry {
            .command(title: title, .spotlightPinFunction(component: target.componentID, pin: target.gatePinPath, function: function))
        }
        switch target.functions.count {
        case 0: break
        case 1: entries.append(command(target.functions[0], title: spotlightTitle(target.functions[0])))
        default: entries.append(.submenu(title: "Spotlight Pins Offering", target.functions.map { command($0, title: $0) }))
        }
        return entries
    }

    /// The Spotlight's free pin `target` is, where a click on it would move
    /// the function's net there.
    static func movable(
        _ target: HorizontalPinFunctionTarget,
        actions: HorizontalPinSpotlightActions?
    ) -> HorizontalPinFunctionSpotlight.Pin? {
        guard let actions, actions.canMove, let spotlight = actions.spotlight, spotlight.carrying != nil,
              spotlight.componentID == target.componentID.lowercased()
                || spotlight.boardComponentIDs.contains(target.componentID.lowercased()),
              let pin = spotlight.pin(gateID: target.gateID, pinID: target.pinID), pin.standing == .free else {
            return nil
        }
        return pin
    }

    /// The pin of the sheet nearest `point`, among the symbols `symbolIDs`
    /// names or, with none named, every symbol on the sheet.
    static func target(
        at point: HorizontalPoint?,
        symbolID: String? = nil,
        in sheet: HorizontalSchematicSheet
    ) -> HorizontalPinFunctionTarget? {
        guard let point else {
            return nil
        }
        let symbols = sheet.symbols.filter { symbolID == nil || $0.id.lowercased() == symbolID?.lowercased() }
        for symbol in symbols {
            guard let pin = HorizontalSchematicPinNoConnect.pin(of: symbol.id, nearest: point, in: sheet),
                  let names = symbol.symbolPinNames.first(where: { $0.id.lowercased() == pin.pinID }) else { continue }
            return HorizontalPinFunctionTarget(
                componentID: pin.componentID, gateID: pin.gateID, pinID: pin.pinID, pinName: names.primaryName,
                functions: HorizontalPinFunctions.names(in: names.alternateNames.map(\.name))
            )
        }
        return nil
    }

    /// The pad of the board under `point`, as `(component, pad)`: a pad of
    /// a package that is some component's. Pads on the layer being worked
    /// on come first where two overlap.
    static func pad(at point: HorizontalPoint, in board: HorizontalBoard, preferringLayer layer: Int? = nil) -> (componentID: String, padID: String)? {
        var found: (componentID: String, padID: String)?
        for polygon in board.packagePads where HorizontalBoardOutlines.contains(point, in: polygon.vertices) {
            guard let path = HorizontalBoard.padPath(forPadPolygonID: polygon.id) else { continue }
            let pieces = path.split(separator: "/").map(String.init)
            guard pieces.count == 2,
                  let componentID = board.packages.first(where: { $0.id.lowercased() == pieces[0] })?.componentID else { continue }
            if polygon.layer == layer || layer == nil {
                return (componentID.lowercased(), pieces[1])
            }
            found = found ?? (componentID.lowercased(), pieces[1])
        }
        return found
    }
}

/// Gives the canvases under it the pin Spotlight (`horizonPinSpotlight`)
/// and keeps the one showing: made from the project as it is when asked
/// for, and made again once a move has changed which pin carries it.
struct HorizontalPinSpotlightSource: ViewModifier {
    var project: () -> HorizontalProject?
    var canMove: Bool
    /// A block's component as the board names its uses.
    var boardComponentIDs: (Set<String>) -> Set<String>
    /// Applies an edit, with its undo title.
    var apply: ([JSONDictionary], String) -> Void

    @State private var spotlight: HorizontalPinFunctionSpotlight?

    func body(content: Content) -> some View {
        content.environment(\.horizonPinSpotlight, HorizontalPinSpotlightActions(
            spotlight: spotlight,
            canMove: canMove,
            show: { componentID, path, function in
                spotlight = made(componentID: componentID, askedFrom: path, function: function)
            },
            clear: { spotlight = nil },
            move: { pin in
                guard canMove, let current = spotlight, let edit = current.move(to: pin) else { return }
                apply(edit.ops, edit.actionName)
                // The edit reaches the project this turn or the next; the
                // Spotlight is made again from it, asked from the new pin.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard spotlight == current else { return }
                    spotlight = made(componentID: current.componentID, askedFrom: pin.gatePinPath, function: current.function)
                }
            },
            padTarget: { componentID, padID in
                guard let component = component(componentID) else { return nil }
                return Self.target(padID: padID, of: component, as: componentID)
            }
        ))
    }

    /// A component by the id a canvas has for it: its block's, or, for one
    /// use of a block's component on the board, that component of the block.
    private func component(_ componentID: String) -> HorizontalDesignComponent? {
        guard let project = project() else { return nil }
        let index = HorizontalDesignIndex(project: project)
        guard let component = index.component(id: componentID) else { return nil }
        return component.instanceOf.flatMap { index.component(id: $0) } ?? component
    }

    private func made(componentID: String, askedFrom path: String?, function: String) -> HorizontalPinFunctionSpotlight? {
        guard let component = component(componentID),
              var made = HorizontalPinFunctionSpotlight(component: component, askedFrom: path, function: function) else {
            return nil
        }
        made.boardComponentIDs = Set(boardComponentIDs([made.componentID]).map { $0.lowercased() })
        return made
    }

    static func target(padID: String, of component: HorizontalDesignComponent, as componentID: String) -> HorizontalPinFunctionTarget? {
        let padID = padID.lowercased()
        guard let pin = component.pins.first(where: { $0.physicalPads.contains { $0.id.lowercased() == padID } }) else {
            return nil
        }
        return HorizontalPinFunctionTarget(
            componentID: componentID.lowercased(), gateID: pin.gateID.lowercased(), pinID: pin.pinID.lowercased(), pinName: pin.pinName,
            functions: HorizontalPinFunctions.names(in: pin.alternates.map(\.name))
        )
    }
}

extension View {
    func pinFunctionSpotlight(
        project: @escaping () -> HorizontalProject?,
        canMove: Bool,
        boardComponentIDs: @escaping (Set<String>) -> Set<String>,
        apply: @escaping ([JSONDictionary], String) -> Void
    ) -> some View {
        modifier(HorizontalPinSpotlightSource(project: project, canMove: canMove, boardComponentIDs: boardComponentIDs, apply: apply))
    }
}
