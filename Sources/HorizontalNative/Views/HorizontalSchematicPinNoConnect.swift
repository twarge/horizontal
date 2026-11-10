import Foundation

/// Horizon's Set NC and Clear NC for one pin (`ToolSetNotConnected`), from
/// the right-click menu on a placed symbol: the pin the pointer is over is
/// marked deliberately not connected, or has its mark cleared. A pin on a
/// net is neither: it is connected, and Set NC would have to take it off its
/// net first, which the menu leaves to Disconnect.
///
/// The edit is the automation channel's `set_no_connect` for that one pin,
/// so the app and an automation client write the same null-net connection
/// Horizon writes.
enum HorizontalSchematicPinNoConnect {
    /// A pin of a placed symbol, with what its component says of it.
    struct Pin: Equatable {
        var symbolID: String
        var componentID: String
        var gateID: String
        var pinID: String
        var name: String
        var state: SchematicConnectionState?

        /// The component's connection key for the pin, `gate/pin`.
        var gatePinPath: String { "\(gateID)/\(pinID)" }
    }

    /// How far from a pin's line the pointer may be and still name it: half
    /// the usual 2.54 mm pin pitch, so neighbouring pins never both qualify.
    static let tolerance = 1_270_000.0

    static func setTitle(_ name: String) -> String { "Set Pin \(name) NC" }
    static func clearTitle(_ name: String) -> String { "Clear Pin \(name) NC" }

    /// The pin of symbol `symbolID` nearest `point`, within `tolerance` of
    /// the line the symbol draws for it. Nil when no pin is that close, or
    /// the symbol draws no component's gate.
    static func pin(
        of symbolID: String,
        nearest point: HorizontalPoint,
        in sheet: HorizontalSchematicSheet,
        tolerance: Double = tolerance
    ) -> Pin? {
        let symbolKey = symbolID.lowercased()
        guard let symbol = sheet.symbols.first(where: { $0.id.lowercased() == symbolKey }),
              let componentID = symbol.componentID?.lowercased(),
              let gateID = symbol.gateID?.lowercased() else {
            return nil
        }
        var best: (pinID: String, distance: Double)?
        for segment in sheet.symbolPins {
            // A pin's own line is `<symbol>/pin/<pin>`; its direction marks
            // and connector strokes carry other kinds.
            let parts = segment.id.lowercased().split(separator: "/").map(String.init)
            guard parts.count == 3, parts[0] == symbolKey, parts[1] == "pin" else { continue }
            let distance = distance(from: point, to: segment)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (parts[2], distance)
            }
        }
        guard let pinID = best?.pinID else {
            return nil
        }
        let names = symbol.symbolPinNames.first { $0.id.lowercased() == pinID }
        var state: SchematicConnectionState?
        for (path, value) in sheet.componentInfo[componentID]?.connections ?? [:]
            where path.lowercased() == "\(gateID)/\(pinID)" {
            state = value
        }
        return Pin(symbolID: symbolKey, componentID: componentID, gateID: gateID, pinID: pinID,
                   name: names?.primaryName ?? String(pinID.prefix(8)), state: state)
    }

    /// The right-click menu's entry for the pin under `point` on the symbol
    /// `ref` names: Set Pin … NC for a pin on no net, Clear Pin … NC for one
    /// marked, nothing for a connected pin or anything that isn't a symbol.
    static func menuEntries(
        for ref: HorizontalSelectableRef,
        at point: HorizontalPoint?,
        in sheet: HorizontalSchematicSheet
    ) -> [HorizontalTargetItemMenuEntry] {
        guard ref.type == .schematicSymbol, let point, let pin = pin(of: ref.id, nearest: point, in: sheet) else {
            return []
        }
        switch pin.state {
        case nil:
            return [.command(title: setTitle(pin.name), .setPinNoConnect(symbol: pin.symbolID, pin: pin.pinID, mark: true))]
        case .notConnected?:
            return [.command(title: clearTitle(pin.name), .setPinNoConnect(symbol: pin.symbolID, pin: pin.pinID, mark: false))]
        case .connected?:
            return []
        }
    }

    /// The edit marking (`mark`) or clearing pin `pinID` of symbol
    /// `symbolID`, with its undo title; nil when the symbol or pin is gone,
    /// or the edit would change nothing.
    static func edit(
        symbol symbolID: String,
        pin pinID: String,
        mark: Bool,
        in sheet: HorizontalSchematicSheet
    ) -> (ops: [JSONDictionary], actionName: String)? {
        guard let symbol = sheet.symbols.first(where: { $0.id.lowercased() == symbolID.lowercased() }),
              let componentID = symbol.componentID?.lowercased(),
              let gateID = symbol.gateID?.lowercased() else {
            return nil
        }
        let pinID = pinID.lowercased()
        var state: SchematicConnectionState?
        for (path, value) in sheet.componentInfo[componentID]?.connections ?? [:]
            where path.lowercased() == "\(gateID)/\(pinID)" {
            state = value
        }
        switch (state, mark) {
        case (nil, true), (.notConnected?, false):
            break
        default:
            return nil
        }
        let name = symbol.symbolPinNames.first { $0.id.lowercased() == pinID }?.primaryName ?? String(pinID.prefix(8))
        let op: JSONDictionary = ["op": "set_no_connect", "component": componentID, "gate": gateID,
                                  "pin": pinID, "no_connect": mark]
        return ([op], mark ? setTitle(name) : clearTitle(name))
    }

    private static func distance(from point: HorizontalPoint, to segment: HorizontalSegment) -> Double {
        let dx = segment.to.x - segment.from.x, dy = segment.to.y - segment.from.y
        let lengthSquared = dx * dx + dy * dy
        var t = 0.0
        if lengthSquared > 0 {
            t = max(0, min(1, ((point.x - segment.from.x) * dx + (point.y - segment.from.y) * dy) / lengthSquared))
        }
        let x = segment.from.x + t * dx - point.x, y = segment.from.y + t * dy - point.y
        return (x * x + y * y).squareRoot()
    }
}
