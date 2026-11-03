import Foundation

/// The board's rules kept applied to everything that takes its shape from
/// them, as Horizon's Apply gives it (`BoardRules::apply`):
/// - a track or net tie whose width is the rules' takes its track width
///   rule's default on its layer (`HorizontalTrackWidthRules`);
/// - a via whose shape is the rules' takes the padstack and parameters of the
///   via rule that matches its net, and one whose shape is a via
///   definition's takes the definition's padstack, parameters and span;
/// - a plane whose settings are the rules' takes its plane rule's.
///
/// Horizon does this only when its rules window's Apply is pressed, so a
/// board it wrote can disagree with its rules. Horizontal does it whenever
/// the board or its rules change: the canvas after every edit, and the
/// document after a change to the rules or the netlist. The rules'
/// parameters shape the pads as the board loads, so a change to those goes
/// through a reload instead. Opening a board changes nothing.
enum HorizontalBoardRuleApplication {
    /// The objects an application changed, by id.
    struct Changes: Equatable {
        /// Tracks and net ties.
        var tracks: [String] = []
        var vias: [String] = []
        var planes: [String] = []

        var isEmpty: Bool {
            tracks.isEmpty && vias.isEmpty && planes.isEmpty
        }

        /// "2 tracks and 1 via", for a status line; nil when nothing changed.
        var summary: String? {
            let parts = [
                Self.count(tracks.count, "track"),
                Self.count(vias.count, "via"),
                Self.count(planes.count, "plane"),
            ].compactMap { $0 }
            switch parts.count {
            case 0: return nil
            case 1: return parts[0]
            default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
            }
        }

        private static func count(_ count: Int, _ noun: String) -> String? {
            count == 0 ? nil : "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
    }

    /// Applies the board's rules to `board`, and says what it changed.
    /// `poolURL` is the project pool, where a via's padstack is read.
    @discardableResult
    static func apply(to board: inout HorizontalBoard, poolURL: URL?) -> Changes {
        var changes = Changes()
        changes.tracks = HorizontalTrackWidthRules.apply(to: &board)
        var padstacks = PadstackLookup(poolURL: poolURL)
        let copperLayers = copperLayers(of: board)
        for index in board.vias.indices {
            var via = board.vias[index]
            guard shape(&via, rules: board.rules, definitions: board.viaDefinitions,
                        viaMaskExpansion: board.ruleViaMaskExpansion, copperLayers: copperLayers,
                        padstacks: &padstacks) else {
                continue
            }
            board.vias[index] = via
            board.syncHole(of: via)
            changes.vias.append(via.id)
        }
        for index in board.planes.indices where applySettings(to: &board.planes[index], rules: board.rules) {
            changes.planes.append(board.planes[index].id)
        }
        return changes
    }

    /// Whether going from `previous` to `rules` changes the rules'
    /// parameters, which shape the pads' and vias' mask openings, the paste
    /// and the courtyards as the board loads: a change to them is applied by
    /// a reload.
    static func parametersChange(from previous: JSONDictionary, to rules: JSONDictionary) -> Bool {
        let before = previous["parameters"] as? JSONDictionary ?? [:]
        let after = rules["parameters"] as? JSONDictionary ?? [:]
        return !NSDictionary(dictionary: before).isEqual(to: after)
    }

    /// Gives `via` the shape the rules or its via definition give it, as
    /// applying the rules does; a via with a shape of its own is left as it
    /// is. Returns whether it changed.
    @discardableResult
    static func shape(_ via: inout HorizontalMarker, in board: HorizontalBoard, poolURL: URL?) -> Bool {
        var padstacks = PadstackLookup(poolURL: poolURL)
        return shape(&via, rules: board.rules, definitions: board.viaDefinitions,
                     viaMaskExpansion: board.ruleViaMaskExpansion, copperLayers: copperLayers(of: board),
                     padstacks: &padstacks)
    }

    /// Gives a plane whose settings are the rules' the settings of the plane
    /// rule that takes its net on its layer, as Horizon's Apply does
    /// (`get_plane_settings`); a plane with settings of its own, or on no
    /// net, is left as it is. The pour reads the rules for such a plane
    /// already; this keeps what the file and the inspector say in step.
    @discardableResult
    static func applySettings(to plane: inout HorizontalPlane, rules: HorizontalBoardRules) -> Bool {
        guard plane.fromRules, let net = plane.netID else {
            return false
        }
        let settings = rules.planeSettings(net: net.lowercased(), layer: plane.layer ?? 10000)
        guard plane.settings != settings else {
            return false
        }
        plane.takeSettings(settings)
        return true
    }

    /// What a via is to look like: a padstack, its parameters and, for a
    /// definition's, a span.
    private struct ViaShape {
        var padstackID: String
        var parameters: [String: Double]
        var span: HorizontalViaSpan?
    }

    /// The shape the rules give `via`: the first enabled via rule by order
    /// that takes its net, for a via from the rules on a net
    /// (`BoardRules::apply` for VIA); its definition, for one from a via
    /// definition (for VIA_DEFINITIONS). Nil where neither names a padstack,
    /// or the via's shape is its own.
    private static func targetShape(
        of via: HorizontalMarker,
        rules: HorizontalBoardRules,
        definitions: [HorizontalViaDefinition],
        padstacks: inout PadstackLookup
    ) -> ViaShape? {
        if via.fromRules {
            guard let net = via.netID, let rule = padstacks.viaRule(net: net, in: rules), let padstack = rule.padstackID else {
                return nil
            }
            return ViaShape(padstackID: padstack, parameters: rule.parameterSet, span: nil)
        }
        guard let definitionID = via.definitionID?.lowercased(),
              let definition = definitions.first(where: { $0.id.lowercased() == definitionID }),
              let padstack = definition.padstackID, !padstack.isEmpty, !isNullUUID(padstack) else {
            return nil
        }
        return ViaShape(padstackID: padstack, parameters: definition.parameters, span: definition.span ?? .through)
    }

    private static func shape(
        _ via: inout HorizontalMarker,
        rules: HorizontalBoardRules,
        definitions: [HorizontalViaDefinition],
        viaMaskExpansion: Double,
        copperLayers: [Int],
        padstacks: inout PadstackLookup
    ) -> Bool {
        guard let target = targetShape(of: via, rules: rules, definitions: definitions, padstacks: &padstacks) else {
            return false
        }
        let samePadstack = via.padstackID?.lowercased() == target.padstackID.lowercased()
        let targetLayers = target.span?.layers(of: copperLayers)
        let sameSpan = targetLayers == nil
            || (targetLayers == via.connectedLayers && (via.span == nil || via.span == target.span))
        // The set as the writer writes it: its own, with the via's diameter
        // and hole, which the drawing takes from the padstack where the set
        // leaves them out.
        var current = via.parameterSet
        current["via_diameter"] = via.size
        if let hole = via.holeSize {
            current["hole_diameter"] = hole
        }
        if samePadstack, sameSpan, current == target.parameters {
            return false
        }
        // As Horizon's Apply, only a padstack the pool has; a padstack id
        // being typed into the rules names none until it is whole.
        guard let padstackJSON = padstacks.padstack(target.padstackID) else {
            return false
        }
        var effective = (padstackJSON.dictionary("parameter_set") ?? [:]).reduce(into: [String: Double]()) { result, item in
            if let number = item.value as? NSNumber {
                result[item.key] = number.doubleValue
            }
        }
        for (key, value) in target.parameters {
            effective[key] = value
        }
        let size = effective["via_diameter"] ?? 500_000
        let hole = effective["hole_diameter"]
        var wanted = target.parameters
        wanted["via_diameter"] = size
        if let hole {
            wanted["hole_diameter"] = hole
        }
        if samePadstack, sameSpan, current == wanted {
            return false
        }
        via.padstackID = target.padstackID
        via.parameterSet = target.parameters
        via.size = size
        via.holeSize = hole
        let parameters = target.parameters.reduce(into: JSONDictionary()) { result, item in
            result[item.key] = item.value
        }
        let masks = HorizontalBoard.viaMaskExpansions(
            padstackJSON: padstackJSON, parameterSet: parameters, viaDiameter: size, boardMaskExpansion: viaMaskExpansion)
        via.topMaskExpansion = masks.top
        via.bottomMaskExpansion = masks.bottom
        if let span = target.span, let targetLayers {
            via.span = span
            via.connectedLayers = targetLayers
        }
        return true
    }

    /// The board's copper layers, top first.
    private static func copperLayers(of board: HorizontalBoard) -> [Int] {
        let layers = board.stackupLayers.map(\.layer).filter(HorizontalBoardLayers.isCopper).sorted(by: >)
        return layers.isEmpty ? [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper] : layers
    }

    private static func isNullUUID(_ id: String) -> Bool {
        id.lowercased() == "00000000-0000-0000-0000-000000000000"
    }

    /// Padstacks read, and via rules looked up, once per application: a
    /// rule's match can be a regular expression.
    private struct PadstackLookup {
        var poolURL: URL?
        private var read = [String: JSONDictionary?]()
        private var viaRules = [String: HorizontalRuleVia?]()

        init(poolURL: URL?) {
            self.poolURL = poolURL
        }

        mutating func viaRule(net: String, in rules: HorizontalBoardRules) -> HorizontalRuleVia? {
            let key = net.lowercased()
            if let cached = viaRules[key] {
                return cached
            }
            let rule = rules.via(net: net)
            viaRules[key] = .some(rule)
            return rule
        }

        mutating func padstack(_ id: String) -> JSONDictionary? {
            let key = id.lowercased()
            if let cached = read[key] {
                return cached
            }
            let padstack = HorizontalBoard.viaPadstack(id, poolURL: poolURL)
            read[key] = .some(padstack)
            return padstack
        }
    }
}

extension HorizontalViaSpan {
    /// Top to bottom copper, Horizon's `layer_range_through`.
    static let through = HorizontalViaSpan(start: HorizontalBoardLayers.topCopper, end: HorizontalBoardLayers.bottomCopper)
}

extension HorizontalPlane {
    /// `settings`, with the mirrored fields (`fillStyle`, `minWidth`,
    /// `keepOrphans`) in step.
    mutating func takeSettings(_ settings: HorizontalPlaneSettings) {
        self.settings = settings
        fillStyle = settings.fillStyle == .hatch ? "hatch" : "solid"
        minWidth = Double(settings.minWidth)
        keepOrphans = settings.keepOrphans
    }
}

extension HorizontalBoard {
    /// A via's drill, its own board hole object, at the via's hole size.
    mutating func syncHole(of via: HorizontalMarker) {
        guard let holeSize = via.holeSize else {
            return
        }
        let holeID = via.id.lowercased() + "/hole"
        guard let index = viaHoles.firstIndex(where: { $0.id.lowercased() == holeID }) else {
            guard holeSize > 0 else {
                return
            }
            viaHoles.append(HorizontalHole(
                id: "\(via.id)/hole", position: via.position, diameter: holeSize, length: holeSize,
                shape: .round, plated: true, netID: via.netID))
            return
        }
        viaHoles[index].diameter = holeSize
        viaHoles[index].length = holeSize
    }
}
