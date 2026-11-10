import Foundation

/// The rows of a placed symbol's inspector that Horizon's schematic symbol
/// property editor has and the sheet's own edit can't make: which pool
/// symbol draws the gate (a unit is often drawn by several — a European and
/// an American resistor, a compact and a full op-amp), how the pins show
/// their names (Pin display mode) and whether a pin with several pads lists
/// them all (Display all pads).
///
/// Each change goes through the automation channel's edits — `place_symbol`
/// with `symbol` for the variant, `set_symbol_display` for the other two —
/// so the app writes the symbol instance exactly as an automation client
/// does, and the reload is one undo step.
enum HorizontalSchematicSymbolProperties {
    static let symbolID = "poolSymbol"
    static let pinDisplayModeID = "symbolPinDisplayMode"
    static let displayAllPadsID = "symbolDisplayAllPads"

    /// A pool symbol that can draw a gate.
    struct SymbolChoice: Hashable {
        var id: String
        var name: String
    }

    /// The project pool's symbols that draw the unit symbol `symbolID`
    /// draws, `symbolID` among them, sorted by name as Horizon's symbol
    /// chooser lists them. Empty when `symbolID` isn't in the pool.
    static func symbols(drawingTheUnitOf symbolID: String, poolURL: URL) -> [SymbolChoice] {
        // Where the loaders look: `symbols/cache/<uuid>.json` first, then the
        // project's own symbols anywhere else under `symbols/`.
        var urls = HorizontalProjectPoolIndex.items(.symbol, poolURL: poolURL)
        let cache = poolURL.appendingPathComponent("symbols/cache", isDirectory: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension.lowercased() == "json" {
            urls[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }
        let summaries = urls.compactMap { id, url in SymbolSummaryCache.summary(at: url).map { (id, $0) } }
        guard let unit = summaries.first(where: { $0.0 == symbolID.lowercased() })?.1.unit else {
            return []
        }
        return summaries
            .filter { $0.1.unit == unit }
            .map { SymbolChoice(id: $0.0, name: $0.1.name.isEmpty ? String($0.0.prefix(8)) : $0.1.name) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// The rows for `placement`: Symbol, a choice when the pool has more
    /// than one symbol for its unit, then Pin display mode and Display all
    /// pads. Read-only where the project can't be edited; none for a symbol
    /// drawing no component's gate.
    static func properties(
        for placement: HorizontalPlacement,
        symbols: [SymbolChoice],
        editable: Bool
    ) -> [HorizontalSelectionProperty] {
        guard placement.componentID != nil, placement.gateID != nil else {
            return []
        }
        var properties = [HorizontalSelectionProperty]()
        let current = placement.symbolID?.lowercased()
        if let current, let chosen = symbols.first(where: { $0.id == current }) {
            if editable, symbols.count > 1 {
                properties.append(HorizontalSelectionProperty(
                    id: symbolID, label: "Symbol",
                    editor: .choice(symbols.map { HorizontalSelectionPropertyOption(id: $0.id, title: $0.name) }),
                    value: .choice(chosen.id)
                ))
            } else {
                properties.append(HorizontalSelectionProperty(id: symbolID, label: "Symbol", editor: .readOnly, value: .readOnly(chosen.name)))
            }
        }
        let mode = HorizontalSymbolPinDisplayMode(rawValue: placement.pinDisplayMode) ?? .selectedOnly
        if editable {
            properties.append(HorizontalSelectionProperty(
                id: pinDisplayModeID, label: "Pin display mode",
                editor: .choice(HorizontalSymbolPinDisplayMode.allCases.map { HorizontalSelectionPropertyOption(id: $0.rawValue, title: $0.title) }),
                value: .choice(mode.rawValue)
            ))
            properties.append(HorizontalSelectionProperty(id: displayAllPadsID, label: "Display all pads", editor: .bool,
                                                          value: .bool(placement.displayAllPads)))
        } else {
            properties.append(HorizontalSelectionProperty(id: pinDisplayModeID, label: "Pin display mode", editor: .readOnly,
                                                          value: .readOnly(mode.title)))
            properties.append(HorizontalSelectionProperty(id: displayAllPadsID, label: "Display all pads", editor: .readOnly,
                                                          value: .readOnly(placement.displayAllPads ? "Yes" : "No")))
        }
        return properties
    }

    /// Whether `propertyID` is one of these rows'.
    static func handles(_ propertyID: String) -> Bool {
        [symbolID, pinDisplayModeID, displayAllPadsID].contains(propertyID)
    }

    /// The edit a change to one of these rows makes, as project edit ops,
    /// with its undo title: on `placement`, or for Pin display mode and
    /// Display all pads on every one of `placements` (the inspector's apply
    /// to all). Nil when it changes nothing.
    static func edit(
        propertyID: String,
        value: HorizontalSelectionPropertyValue,
        placements: [HorizontalPlacement]
    ) -> (ops: [JSONDictionary], actionName: String)? {
        switch (propertyID, value) {
        case (symbolID, .choice(let chosen)):
            // One symbol is changed at a time: a choice names one symbol.
            guard let placement = placements.first, let componentID = placement.componentID, let gateID = placement.gateID,
                  placement.symbolID?.lowercased() != chosen.lowercased() else {
                return nil
            }
            return ([["op": "place_symbol", "component": componentID.lowercased(), "gate": gateID.lowercased(),
                      "symbol": chosen.lowercased()]], "Change Symbol")
        case (pinDisplayModeID, .choice(let mode)):
            guard HorizontalSymbolPinDisplayMode(rawValue: mode) != nil else { return nil }
            let ops: [JSONDictionary] = placements
                .filter { $0.componentID != nil && $0.pinDisplayMode != mode }
                .map { ["op": "set_symbol_display", "symbol_instance": $0.id.lowercased(), "pin_display_mode": mode] }
            return ops.isEmpty ? nil : (ops, "Set Pin Display Mode")
        case (displayAllPadsID, .bool(let all)):
            let ops: [JSONDictionary] = placements
                .filter { $0.componentID != nil && $0.displayAllPads != all }
                .map { ["op": "set_symbol_display", "symbol_instance": $0.id.lowercased(), "display_all_pads": all] }
            return ops.isEmpty ? nil : (ops, all ? "Display All Pads" : "Display One Pad")
        default:
            return nil
        }
    }
}

/// A pool symbol file's unit and name, read once for each version of the
/// file: the inspector asks for a symbol's siblings every time a symbol is
/// selected, and a project pool's symbols seldom change.
private enum SymbolSummaryCache {
    struct Summary {
        var unit: String
        var name: String
        var modified: Date?
    }

    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var summaries = [String: Summary]()

    static func summary(at url: URL) -> Summary? {
        let path = url.standardizedFileURL.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        lock.lock()
        if let kept = summaries[path], kept.modified == modified {
            lock.unlock()
            return kept
        }
        lock.unlock()
        guard let json = try? JSONHelper.loadDictionary(from: url), let unit = json.string("unit")?.lowercased() else {
            return nil
        }
        let summary = Summary(unit: unit, name: json.string("name") ?? "", modified: modified)
        lock.lock()
        summaries[path] = summary
        lock.unlock()
        return summary
    }
}
