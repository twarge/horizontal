import Foundation

/// The functions a pin's alternate names offer. A microcontroller's unit
/// gives each port pin the peripheral signals it can carry as alternates
/// (`USART1_TX`, `TIM4_CH1`), and the same signal on every pin that can
/// carry it; one alternate may combine several with a slash
/// (`SPI1_SCK/I2S1_CK`), each a function of its own.
enum HorizontalPinFunctions {
    /// The functions one alternate name holds, in the order it writes them.
    static func names(in alternateName: String) -> [String] {
        alternateName.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Every function the alternates offer, each once, in natural order.
    static func names(in alternateNames: [String]) -> [String] {
        var seen = Set<String>()
        return alternateNames.flatMap(names(in:))
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func offers(_ alternateName: String, _ function: String) -> Bool {
        names(in: alternateName).contains { $0.caseInsensitiveCompare(function) == .orderedSame }
    }
}

/// One function of one component, and every pin of it that offers the
/// function: what a pin Spotlight lights on the schematic, as pins, and on
/// the board, as their pads.
///
/// A pin stands one of three ways. The pin `carrying` the function is the
/// one whose net a click on a free pin moves: the pin the Spotlight was
/// asked from, when it is on a net, or else the one pin on a net that is
/// drawn as the function. A `free` pin is on no net and not marked
/// no-connect, so it can take the net; a `taken` pin can't.
struct HorizontalPinFunctionSpotlight: Equatable {
    enum Standing: String, Equatable {
        case carrying, free, taken
    }

    struct Pin: Equatable {
        var gateID: String
        var pinID: String
        /// The pin's primary name, `PB6`.
        var name: String
        var standing: Standing
        var netID: String?
        /// The package pads the part maps the pin to.
        var padIDs: [String]

        var gatePinPath: String { "\(gateID)/\(pinID)" }
    }

    /// The component as its block's schematic names it, lowercased.
    var componentID: String
    var refdes: String
    var function: String
    var pins: [Pin]
    /// The component as the board names it: itself, or each use of it
    /// where its block is instanced. Set by the window, which knows.
    var boardComponentIDs: Set<String> = []

    var carrying: Pin? { pins.first { $0.standing == .carrying } }
    var freePins: [Pin] { pins.filter { $0.standing == .free } }

    /// Nil when no pin of the component offers `function`. `path` is the
    /// gate/pin the Spotlight was asked from, if it was asked from a pin.
    init?(component: HorizontalDesignComponent, askedFrom path: String? = nil, function: String) {
        let offering = component.pins.compactMap { pin -> (pin: HorizontalDesignPin, alternateIDs: Set<String>)? in
            let ids = pin.alternates.filter { HorizontalPinFunctions.offers($0.name, function) }.map { $0.id.lowercased() }
            return ids.isEmpty ? nil : (pin, Set(ids))
        }
        guard !offering.isEmpty else {
            return nil
        }
        let asked = path?.lowercased()
        var carrying = offering.first { $0.pin.gatePinPath.lowercased() == asked && $0.pin.netID != nil }?.pin.gatePinPath
        if carrying == nil {
            let drawnAsIt = offering.filter { item in
                item.pin.netID != nil && item.pin.selection?.alternateIDs.contains(where: item.alternateIDs.contains) == true
            }
            if drawnAsIt.count == 1 {
                carrying = drawnAsIt[0].pin.gatePinPath
            }
        }
        componentID = component.id.lowercased()
        refdes = component.refdes
        // The function as the unit spells it, not as it was typed.
        self.function = offering.lazy.flatMap { $0.pin.alternates.flatMap { HorizontalPinFunctions.names(in: $0.name) } }
            .first { $0.caseInsensitiveCompare(function) == .orderedSame } ?? function
        pins = offering.map { item in
            let pin = item.pin
            let standing: Standing = pin.gatePinPath == carrying ? .carrying
                : pin.netID == nil && pin.connectionState != "no_connect" ? .free : .taken
            return Pin(gateID: pin.gateID.lowercased(), pinID: pin.pinID.lowercased(), name: pin.pinName, standing: standing,
                       netID: pin.netID, padIDs: pin.physicalPads.map { $0.id.lowercased() })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func pin(gateID: String, pinID: String) -> Pin? {
        let gateID = gateID.lowercased(), pinID = pinID.lowercased()
        return pins.first { $0.gateID == gateID && $0.pinID == pinID }
    }

    /// The pin a pad of the component belongs to, among those lit.
    func pin(padID: String) -> Pin? {
        let padID = padID.lowercased()
        return pins.first { $0.padIDs.contains(padID) }
    }

    /// The lit pins a sheet draws, as `<symbol>/<pin>`, lowercased: the key
    /// every stroke and text of a drawn pin carries in its id
    /// (`<symbol>/pin/<pin>`, `<symbol>/pin-name/<pin>` and the rest).
    func pinKeys(in sheet: HorizontalSchematicSheet) -> Set<String> {
        var keys = Set<String>()
        for symbol in sheet.symbols where symbol.componentID?.lowercased() == componentID {
            guard let gateID = symbol.gateID?.lowercased() else { continue }
            for pin in pins where pin.gateID == gateID {
                keys.insert("\(symbol.id.lowercased())/\(pin.pinID)")
            }
        }
        return keys
    }

    /// The lit pads on a board, as `<board package>/<pad>`, lowercased
    /// (`HorizontalBoard.padPath(forPadPolygonID:)`).
    func padPaths(in board: HorizontalBoard) -> Set<String> {
        var paths = Set<String>()
        for package in board.packages {
            guard let component = package.componentID?.lowercased(),
                  boardComponentIDs.contains(component) || component == componentID else { continue }
            for pin in pins {
                for padID in pin.padIDs {
                    paths.insert("\(package.id.lowercased())/\(padID)")
                }
            }
        }
        return paths
    }

    /// The `<symbol>/<pin>` key of a drawn pin's stroke or text, nil for
    /// anything else a sheet draws.
    static func pinKey(forGeometryID id: String) -> String? {
        let parts = id.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[1].hasPrefix("pin") else {
            return nil
        }
        return "\(parts[0])/\(parts[2])".lowercased()
    }

    /// What a status line says of it: the function, how many pins offer it
    /// and how many of those are free.
    var summary: String {
        let free = freePins.count
        var text = "\(function) on \(refdes): \(pins.count) pin\(pins.count == 1 ? "" : "s")"
        text += " (\(pins.map(\.name).joined(separator: ", ")))"
        if let carrying {
            text += free == 0 ? "; none free to take it from \(carrying.name)"
                : "; click a free one (\(freePins.map(\.name).joined(separator: ", "))) to move it from \(carrying.name)"
        } else if free > 0 {
            text += "; free: \(freePins.map(\.name).joined(separator: ", "))"
        }
        return text
    }

    /// The edit that takes the function's net from the pin carrying it to
    /// `target`, with its undo title; nil where there is no net to move or
    /// the target isn't free.
    func move(to target: Pin) -> (ops: [JSONDictionary], actionName: String)? {
        guard let carrying, target.standing == .free, pins.contains(target) else {
            return nil
        }
        let op: JSONDictionary = ["op": "move_pin_net", "component": componentID, "pin": carrying.gatePinPath,
                                  "to_pin": target.gatePinPath, "function": function]
        return ([op], "Move \(function) to \(target.name)")
    }
}
