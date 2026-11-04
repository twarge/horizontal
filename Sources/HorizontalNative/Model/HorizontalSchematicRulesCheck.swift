import Foundation
import HorizontalProjectIO

/// Horizon's schematic rules (`SchematicRules`), as the top schematic's
/// `rules` holds them. Horizon has one, Connectivity (`RuleConnectivity`),
/// which only checks; files from before it was named call it
/// `single_pin_net`.
struct HorizontalSchematicRules: Equatable, Sendable {
    /// The Connectivity rule's `enabled`.
    var connectivityEnabled = true
    /// `include_unnamed`: whether a net with no name is checked for having
    /// only one pin.
    var includeUnnamedNets = true

    init(connectivityEnabled: Bool = true, includeUnnamedNets: Bool = true) {
        self.connectivityEnabled = connectivityEnabled
        self.includeUnnamedNets = includeUnnamedNets
    }

    /// As `SchematicRules::load_from_json` reads `rules`: `connectivity`, or
    /// `single_pin_net` where there is none. A file without either has
    /// Horizon's defaults, the rule enabled.
    init(json: JSONDictionary?) {
        guard let rule = json?.dictionary("connectivity") ?? json?.dictionary("single_pin_net") else {
            return
        }
        connectivityEnabled = rule.bool("enabled") ?? true
        includeUnnamedNets = rule.bool("include_unnamed") ?? true
    }

    /// `rules` with these in it, as `SchematicRules::serialize` writes them:
    /// `connectivity`, with the order a rule of one instance has, and not the
    /// old name. Anything else `rules` holds stays.
    func json(updating rules: JSONDictionary) -> JSONDictionary {
        var rules = rules
        rules.removeValue(forKey: "single_pin_net")
        rules["connectivity"] = ["enabled": connectivityEnabled, "include_unnamed": includeUnnamedNets, "order": -1] as JSONDictionary
        return rules
    }
}

/// One finding of the schematic's Connectivity rule, with where the
/// schematic draws what it is about.
struct HorizontalSchematicRuleFinding: Identifiable, Hashable, Sendable {
    /// The four things `SchematicRules::check_connectivity` looks for, in the
    /// order it looks.
    enum Check: String, Hashable, Sendable {
        /// A net only one pin is on.
        case onePinNet = "one_pin_net"
        /// A net only one of whose net segments has a label.
        case oneLabelNet = "one_label_net"
        /// A pin on no net and not marked no-connect.
        case unconnectedPin = "unconnected_pin"
        /// A block instance's port on no net and not marked no-connect.
        case unconnectedPort = "unconnected_port"
    }

    /// Where on the schematic a finding is.
    struct Place: Hashable, Sendable {
        /// The block whose sheet it is; nil for a schematic with no blocks.
        var blockID: String?
        var sheetID: String
        var sheetIndex: Int
        var sheetName: String
        var position: HorizontalPoint
    }

    var check: Check
    /// What Horizon says, e.g. `Pin R1.2 is not connected`.
    var message: String
    /// Lowercased: the net the finding is about, and the component whose pin
    /// it is.
    var netID: String? = nil
    var componentID: String? = nil
    /// Nil where no sheet draws it.
    var place: Place? = nil
    /// What it is about, to tell findings of one check apart: a net, a
    /// component's gate and pin, an instance's port.
    var subject: String

    var id: String { "\(check.rawValue)|\(subject)" }

    /// Horizon warns of a net with one labelled segment and fails the rest.
    var isError: Bool { check != .oneLabelNet }

    /// Where it is, as the results sidebar says it.
    var placeDescription: String {
        guard let place else { return "Not drawn on any sheet" }
        return "Sheet \(place.sheetIndex) (\(place.sheetName))"
    }

    /// A region to frame to show it: the point, with room round it.
    var region: HorizontalRect? {
        guard let place else { return nil }
        return HorizontalRect(center: place.position, size: 30_000_000)
    }
}

/// Horizon's schematic Connectivity check (`SchematicRules::check_connectivity`,
/// schematic_rules_check.cpp): a net only one pin is on, unless it is marked
/// no-connect, and, with Include Unnamed Nets off, only a named one; a net
/// only one of whose net segments has a label of its own, across its block's
/// sheets, unless it is a port; every pin of every gate on no net and not
/// marked no-connect, placed or not; and every port of a block instance on
/// no net and not marked no-connect.
///
/// The nets are the flattened design's as `HorizontalDesignIndex` gives them:
/// a top block net's pins every instance's that reach it, a sub-block's own
/// net its block's pins. A sub-block's finding is reported once, for its
/// block, and drawn on its block's sheet; Horizon reports a sub-block net's
/// once per instance and draws a sub-block's findings in the first instance.
enum HorizontalSchematicRulesCheck {
    /// The findings for `project` as `archive` holds it, which the index
    /// reads the blocks and the pool from: the document's archive, which the
    /// files on disk may lag.
    static func findings(
        project: HorizontalProject,
        archive: HorizontalProjectArchive?,
        rules: HorizontalSchematicRules
    ) -> [HorizontalSchematicRuleFinding] {
        guard rules.connectivityEnabled else { return [] }
        let snapshot = archive.map { HorizontalDispatchSnapshot(archive: $0, baseURL: project.baseURL) }
        return findings(project: project, index: HorizontalDesignIndex(project: project, snapshot: snapshot), rules: rules)
    }

    /// The findings, in background, as the clearance check runs; nil when
    /// the task is cancelled first.
    static func backgroundFindings(
        project: HorizontalProject,
        archive: HorizontalProjectArchive?,
        rules: HorizontalSchematicRules
    ) async -> [HorizontalSchematicRuleFinding]? {
        let input = HorizontalUnsafeSendableBox((project, archive))
        let task = Task.detached(priority: .userInitiated) {
            findings(project: input.value.0, archive: input.value.1, rules: rules)
        }
        let findings = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return Task.isCancelled ? nil : findings
    }

    static func findings(
        project: HorizontalProject,
        index: HorizontalDesignIndex,
        rules: HorizontalSchematicRules
    ) -> [HorizontalSchematicRuleFinding] {
        guard rules.connectivityEnabled else { return [] }
        let sheets = Sheets(project: project)
        var findings = [HorizontalSchematicRuleFinding]()

        // One-pin nets. A sub-block's net reaches past its block through the
        // ports of the blocks it uses; a port net reaches past it through its
        // instances' connections, so it is the net it is wired to that counts.
        let noConnectNets = Set(project.flattenedBlock?.noConnectNets.map { $0.lowercased() } ?? [])
        for net in index.sortedNets {
            let reach = net.pins.count + (net.blockID == nil ? 0 : net.ports.count)
            let name = net.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard reach == 1, !net.isPort, !noConnectNets.contains(net.id), let pin = net.pins.first,
                  rules.includeUnnamedNets || !name.isEmpty else { continue }
            let place = sheets.pinPlace(index.components[pin.componentID], gateID: pin.gateID, pinID: pin.pinID)
            let subject = name.isEmpty ? "Unnamed net" : "Net \"\(name)\""
            findings.append(.init(
                check: .onePinNet,
                message: "\(subject) only connected to \(pin.refdes)\(pin.gateSuffix).\(pin.pinName)",
                netID: net.id, componentID: pin.componentID, place: place?.place, subject: net.id
            ))
        }

        // Nets one of whose segments alone has a label of its own, across
        // the sheets of their block.
        for entry in HorizontalDesignIndex.schematics(of: project) {
            var labelled = [String: [(sheet: HorizontalSchematicSheet, segment: HorizontalSchematicNetSegment)]]()
            for sheet in entry.schematic.sheets.sorted(by: { $0.index < $1.index }) {
                for segment in HorizontalSchematicWarnings.netSegments(sheet) where segment.reallyHasLabel {
                    guard let netID = segment.netID?.lowercased(),
                          !(sheet.netDetails[netID]?.isPort ?? false) else { continue }
                    labelled[netID, default: []].append((sheet, segment))
                }
            }
            for (netID, segments) in labelled.sorted(by: { $0.key < $1.key }) where segments.count == 1 {
                let (sheet, segment) = segments[0]
                let name = sheet.netDetails[netID]?.name ?? index.netName(id: netID) ?? ""
                let position = segment.labels.first?.position ?? segment.position
                findings.append(.init(
                    check: .oneLabelNet,
                    message: "Net \"\(name)\" only has one net segment with a label",
                    netID: netID,
                    place: sheets.place(sheet, of: entry, at: position),
                    subject: "\(entry.block.uuid.lowercased())/\(netID)"
                ))
            }
        }

        // Pins on no net. A sub-block's component is named as its first
        // instance names it.
        for component in index.sortedComponents {
            let instanceRefdes = index.instances
                .filter { $0.componentID == component.id && !$0.instancePath.isEmpty }
                .min { ($0.instancePath, $0.refdes) < ($1.instancePath, $1.refdes) }?.refdes
            let refdes = instanceRefdes ?? component.refdes
            for pin in component.pins where pin.connectionState == "unconnected" {
                var message = "Pin \(refdes)\(pin.gateSuffix).\(pin.pinName) is not connected"
                let place = sheets.pinPlace(component, gateID: pin.gateID, pinID: pin.pinID)
                if place == nil {
                    message += " (not found in schematic)"
                } else if place?.drawsPin == false {
                    message += " (Pin not placed in symbol)"
                }
                findings.append(.init(
                    check: .unconnectedPin, message: message, componentID: component.id,
                    place: place?.place, subject: "\(component.id)/\(pin.gatePinPath)"
                ))
            }
        }

        // Block instances' ports on no net, where a sheet draws the instance.
        for entry in HorizontalDesignIndex.schematics(of: project) {
            var seen = Set<String>()
            for sheet in entry.schematic.sheets.sorted(by: { $0.index < $1.index }) {
                for symbol in sheet.blockSymbols where seen.insert(symbol.instanceID).inserted {
                    let wired = Set(symbol.connections.keys.map { $0.lowercased() })
                    let ports = symbol.resource.nets.filter(\.value.isPort)
                        .sorted { ($0.value.name, $0.key) < ($1.value.name, $1.key) }
                    for (portNetID, port) in ports where !wired.contains(portNetID.lowercased()) {
                        let portID = HorizontalBlockSymbolPortID.uuid(forNet: portNetID)
                        let drawn = portID.flatMap { portID in
                            sheet.blockSymbolPorts.first { $0.id.lowercased() == "\(symbol.id)/block-port/\(portID)" }?.from
                        }
                        findings.append(.init(
                            check: .unconnectedPort,
                            message: "Port \(symbol.refdes).\(port.name) is not connected",
                            place: sheets.place(sheet, of: entry, at: drawn ?? symbol.placement.shift),
                            subject: "\(symbol.instanceID)/\(portNetID.lowercased())"
                        ))
                    }
                }
            }
        }
        return findings
    }

    /// Every sheet of every block, in Horizon's order: the top block's first,
    /// then each block's by page.
    private struct Sheets {
        struct Entry {
            var block: HorizontalProjectSchematic
            var sheet: HorizontalSchematicSheet
            var order: Int
        }
        struct PinPlace {
            var place: HorizontalSchematicRuleFinding.Place
            /// False where the symbol doesn't draw the pin, and the place is
            /// the symbol's.
            var drawsPin: Bool
        }

        private var entries = [String: Entry]()
        private let hasBlocks: Bool

        init(project: HorizontalProject) {
            hasBlocks = !project.schematics.isEmpty
            let schematics = HorizontalDesignIndex.schematics(of: project).sorted { ($0.block.isTop ? 0 : 1) < ($1.block.isTop ? 0 : 1) }
            var order = 0
            for schematic in schematics {
                for sheet in schematic.schematic.sheets.sorted(by: { $0.index < $1.index }) {
                    entries[sheet.id.lowercased()] = Entry(block: schematic, sheet: sheet, order: order)
                    order += 1
                }
            }
        }

        func place(_ sheet: HorizontalSchematicSheet, of block: HorizontalProjectSchematic, at position: HorizontalPoint) -> HorizontalSchematicRuleFinding.Place {
            .init(blockID: hasBlocks ? block.block.uuid : nil, sheetID: sheet.id, sheetIndex: sheet.index,
                  sheetName: sheet.name, position: position)
        }

        /// Where the first sheet drawing the gate draws the pin: its end, or
        /// the symbol where the symbol leaves the pin out.
        func pinPlace(_ component: HorizontalDesignComponent?, gateID: String, pinID: String) -> PinPlace? {
            let gateID = gateID.lowercased(), pinID = pinID.lowercased()
            let drawn = (component?.symbolPlacements ?? []).compactMap { placement -> (HorizontalDesignSymbolPlacement, Entry)? in
                guard placement.gateID.lowercased() == gateID, let entry = entries[placement.sheetID.lowercased()] else { return nil }
                return (placement, entry)
            }
            guard let (placement, entry) = drawn.min(by: { $0.1.order < $1.1.order }) else { return nil }
            let pinSegment = "\(placement.symbolID.lowercased())/pin/\(pinID)"
            let pin = entry.sheet.symbolPins.first { $0.id.lowercased() == pinSegment }
            return PinPlace(place: place(entry.sheet, of: entry.block, at: pin?.from ?? placement.position), drawsPin: pin != nil)
        }
    }
}
