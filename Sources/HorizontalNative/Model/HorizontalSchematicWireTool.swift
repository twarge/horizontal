import Foundation

/// The sheet edits behind Horizon's wire tool (`ToolDrawLineNet`): what a
/// click lands on, a wire split where a click lands partway along it, and the
/// wire laid between two clicks with its bend. The canvas drives these and
/// settles the nets (asking when two named nets meet); keeping the edits here
/// lets tests run exactly what the canvas runs.
enum HorizontalSchematicWireTool {
    /// Which way a wire with two legs bends: along x first, or along y.
    enum Bend: Equatable {
        case xy
        case yx
    }

    /// What a click of the tool lands on, in the order Horizon takes its
    /// targets.
    enum Target: Equatable {
        /// A placed pin and its connection (nil for a pin on no net yet).
        case pin(HorizontalSchematicSheet.SchematicPinRef, SchematicConnectionState?)
        /// A block symbol's port, `<block symbol>/<port>`, and its net.
        case port(String, netID: String?)
        case junction(String, netID: String?)
        /// Partway along the wire at this index, which is split there.
        case wire(Int)
        case nothing
    }

    private static func key(_ point: HorizontalPoint) -> String {
        HorizontalCanvasModeSupport.pointKey(point)
    }

    static func target(at point: HorizontalPoint, in sheet: HorizontalSchematicSheet) -> Target {
        if let pin = sheet.schematicPins(at: point).first(where: { sheet.connectionPath(of: $0) != nil }) {
            return .pin(pin, sheet.connection(of: pin))
        }
        let pointKey = key(point)
        for port in sheet.blockSymbolPorts where key(port.from) == pointKey {
            let parts = port.id.lowercased().split(separator: "/").map(String.init)
            if parts.count == 3, parts[1] == "block-port" {
                return .port("\(parts[0])/\(parts[2])", netID: port.netID)
            }
        }
        if let junctionID = sheet.junctions.keys.sorted().first(where: { key(sheet.junctions[$0]!) == pointKey }) {
            return .junction(junctionID, netID: junctionNetID(junctionID, at: point, in: sheet))
        }
        if let index = sheet.netLines.firstIndex(where: { line in
            key(line.from) != pointKey && key(line.to) != pointKey && lies(point, on: line)
        }) {
            return .wire(index)
        }
        return .nothing
    }

    /// A junction's net: its own, else that of a wire ending on it or of
    /// what hangs from it.
    static func junctionNetID(_ junctionID: String, at point: HorizontalPoint, in sheet: HorizontalSchematicSheet) -> String? {
        if let netID = sheet.junctionNetIDs[junctionID] {
            return netID
        }
        let pointKey = key(point)
        return sheet.netLines.first { $0.netID != nil && (key($0.from) == pointKey || key($0.to) == pointKey) }?.netID
            ?? sheet.netLabels.first { $0.netID != nil && key($0.position) == pointKey }?.netID
            ?? sheet.powerSymbols.first { $0.netID != nil && $0.junctionID.lowercased() == junctionID.lowercased() }?.netID
    }

    private static func lies(_ point: HorizontalPoint, on segment: HorizontalSegment) -> Bool {
        guard point.x >= min(segment.from.x, segment.to.x), point.x <= max(segment.from.x, segment.to.x),
              point.y >= min(segment.from.y, segment.to.y), point.y <= max(segment.from.y, segment.to.y) else {
            return false
        }
        let line = segment.to - segment.from
        let candidate = point - segment.from
        return abs(line.x * candidate.y - line.y * candidate.x) < 1
    }

    /// `Sheet::split_line_net`: the wire at `index` becomes two meeting at a
    /// new junction at `point`, on the wire's net. Returns the junction.
    @discardableResult
    static func splitWire(at index: Int, point: HorizontalPoint, in sheet: inout HorizontalSchematicSheet) -> String {
        let line = sheet.netLines[index]
        let junctionID = UUID().uuidString.lowercased()
        sheet.junctions[junctionID] = point
        if let netID = line.netID {
            sheet.junctionNetIDs[junctionID] = netID
        }
        var head = line
        head.to = point
        head.schematicTo = .junction(junctionID)
        var tail = line
        tail.id = UUID().uuidString.lowercased()
        tail.from = point
        tail.schematicFrom = .junction(junctionID)
        sheet.netLines[index] = head
        sheet.netLines.insert(tail, at: index + 1)
        return junctionID
    }

    /// The bend a wire from a pin, port or power symbol starts with: leaving
    /// along it.
    static func bend(at point: HorizontalPoint, in sheet: HorizontalSchematicSheet) -> Bend? {
        let pointKey = key(point)
        for segment in sheet.symbolPins + sheet.blockSymbolPorts + sheet.powerSymbolLines
            where key(segment.from) == pointKey || key(segment.to) == pointKey {
            let vector = segment.to - segment.from
            return abs(vector.y) >= abs(vector.x) ? .yx : .xy
        }
        return nil
    }

    /// The corners of a wire from `anchor` to `point` bending as `bend`
    /// says: two legs, or one when the two points line up.
    static func path(from anchor: HorizontalPoint, to point: HorizontalPoint, bend: Bend) -> [HorizontalPoint] {
        let corner: HorizontalPoint
        switch bend {
        case .xy:
            corner = HorizontalPoint(x: point.x, y: anchor.y)
        case .yx:
            corner = HorizontalPoint(x: anchor.x, y: point.y)
        }
        if key(corner) == key(anchor) || key(corner) == key(point) {
            return [anchor, point]
        }
        return [anchor, corner, point]
    }

    /// Lays the wire from `anchor` to `point` along `path`, with a junction
    /// at its bend and its ends on `start` and `end`, all on `netID`.
    /// Returns the wires added.
    @discardableResult
    static func layWire(
        from anchor: HorizontalPoint,
        start: HorizontalSchematicEndpoint,
        to point: HorizontalPoint,
        end: HorizontalSchematicEndpoint,
        bend: Bend,
        netID: String?,
        in sheet: inout HorizontalSchematicSheet
    ) -> [HorizontalSegment] {
        var added = [HorizontalSegment]()
        var previousPoint = anchor
        var previousEndpoint = start
        for corner in path(from: anchor, to: point, bend: bend).dropFirst() {
            guard key(previousPoint) != key(corner) else {
                continue
            }
            let endpoint: HorizontalSchematicEndpoint
            if key(corner) == key(point) {
                endpoint = end
            } else {
                endpoint = .junction(newJunction(at: corner, netID: netID, in: &sheet))
            }
            let line = HorizontalSegment(
                id: UUID().uuidString.lowercased(),
                from: previousPoint,
                to: corner,
                width: 0,
                layer: nil,
                netID: netID,
                schematicFrom: previousEndpoint,
                schematicTo: endpoint
            )
            sheet.netLines.append(line)
            added.append(line)
            previousPoint = corner
            previousEndpoint = endpoint
        }
        return added
    }

    /// One run of the tool: the clicks Horizon's `ToolDrawLineNet::update`
    /// takes, on a draft of the sheet. A click on nothing places a corner and
    /// goes on; a click on a pin, port, junction or the side of a wire ends
    /// the wire there and the next click starts a new one. The wire takes the
    /// net of the first thing it touches, a pin on no net yet joins the
    /// wire's, and two nets that meet merge — the target's into the wire's,
    /// by Horizon's rules, `.ask` when both have names.
    struct Session {
        var originalSheet: HorizontalSchematicSheet
        var sheet: HorizontalSchematicSheet
        /// Where the wire being drawn starts; nil between wires.
        var anchor: HorizontalPoint?
        /// What it starts on; nil for a junction still to be made there.
        var anchorEndpoint: HorizontalSchematicEndpoint?
        /// The pin it started on, which it cannot end on.
        var startPin: String?
        var netID: String?
        var bend: Bend = .xy
        var segmentCount = 0
        /// The sheet changed: a wire went down, or one was split.
        var hasChanges = false
        /// Nets the project had that this run merged away, by survivor.
        var externalMerges: [String: String] = [:]
        /// A click waiting on the user's answer to `.ask`.
        private var pending: (point: HorizontalPoint, target: Target)?

        enum Outcome: Equatable {
            case done
            /// Nothing happened; Horizon flashes the message.
            case refused(String)
            /// Two named nets meet: `resolve` with the user's choice.
            case ask(net: String, into: String)
        }

        init(sheet: HorizontalSchematicSheet) {
            originalSheet = sheet
            self.sheet = sheet
        }

        /// Nets this run made, for pins it reached first: they give way to
        /// existing nets and never need rewriting elsewhere.
        var newNetIDs: Set<String> {
            Set(sheet.netDetails.keys).subtracting(originalSheet.netDetails.keys)
        }

        private static let noConnectMessage = "Can't connect to a pin marked no connect"
        private static let noConnectPortMessage = "Can't connect to a port marked no connect"

        /// Whether the port at `path` is marked NC, which Horizon won't wire.
        private func isNoConnectPort(_ path: String) -> Bool {
            if case .notConnected? = sheet.blockPortConnection(path: path) { return true }
            return false
        }

        mutating func click(at point: HorizontalPoint) -> Outcome {
            pending = nil
            let target = HorizontalSchematicWireTool.target(at: point, in: sheet)
            guard let anchor else {
                return start(at: point, on: target)
            }
            // A second click where the wire is ends it, as Horizon's restart.
            guard key(anchor) != key(point) else {
                restart()
                return .done
            }
            let targetNetID: String?
            switch target {
            case .pin(let pin, let connection):
                if case .notConnected? = connection { return .refused(Self.noConnectMessage) }
                guard pin.path != startPin else { return .done }
                targetNetID = connection?.netID
            case .port(let path, let netID):
                if isNoConnectPort(path) { return .refused(Self.noConnectPortMessage) }
                targetNetID = netID
            case .junction(_, let netID):
                targetNetID = netID
            case .wire(let index):
                targetNetID = sheet.netLines[index].netID
            case .nothing:
                targetNetID = nil
            }
            guard let wireNetID = netID, let targetNetID, wireNetID.lowercased() != targetNetID.lowercased() else {
                netID = netID ?? targetNetID
                finish(at: point, on: target)
                return .done
            }
            switch sheet.netMergeVerdict(targetNetID, into: wireNetID, preferring: newNetIDs) {
            case .merge(let from, let into):
                merge(from, into: into)
                finish(at: point, on: target)
                return .done
            case .refuse(let message):
                return .refused(message)
            case .ask(let net, let into):
                pending = (point, target)
                return .ask(net: net, into: into)
            }
        }

        /// Finishes the click that asked, with the merge the user chose, or
        /// drops it when they cancelled.
        mutating func resolve(_ choice: (from: String, into: String)?) -> Outcome {
            guard let pending, let choice else {
                self.pending = nil
                return .done
            }
            self.pending = nil
            merge(choice.from, into: choice.into)
            finish(at: pending.point, on: pending.target)
            return .done
        }

        private mutating func start(at point: HorizontalPoint, on target: Target) -> Outcome {
            switch target {
            case .pin(let pin, let connection):
                if case .notConnected? = connection { return .refused(Self.noConnectMessage) }
                anchorEndpoint = .pin(pin.path)
                startPin = pin.path
                netID = connection?.netID
            case .port(let path, let netID):
                // A port on no net gets one when the wire is laid, as a pin does.
                if isNoConnectPort(path) { return .refused(Self.noConnectPortMessage) }
                anchorEndpoint = .port(path)
                self.netID = netID
            case .junction(let junctionID, let netID):
                anchorEndpoint = .junction(junctionID)
                self.netID = netID
            case .wire(let index):
                netID = sheet.netLines[index].netID
                anchorEndpoint = .junction(HorizontalSchematicWireTool.splitWire(at: index, point: point, in: &sheet))
                hasChanges = true
            case .nothing:
                anchorEndpoint = nil
                netID = nil
            }
            anchor = point
            bend = HorizontalSchematicWireTool.bend(at: point, in: sheet) ?? bend
            return .done
        }

        /// `/`: Horizon's posture, the other way round the corner.
        mutating func flipBend() {
            bend = bend == .xy ? .yx : .xy
        }

        private mutating func merge(_ from: String, into: String) {
            let from = from.lowercased(), into = into.lowercased()
            sheet.mergeNet(from, into: into)
            if originalSheet.netDetails[from] != nil {
                for (merged, survivor) in externalMerges where survivor == from {
                    externalMerges[merged] = into
                }
                externalMerges[from] = into
            }
            netID = into
        }

        private mutating func finish(at point: HorizontalPoint, on target: Target) {
            guard let anchor else { return }
            let end: HorizontalSchematicEndpoint
            switch target {
            case .pin(let pin, _):
                end = .pin(pin.path)
            case .port(let path, _):
                end = .port(path)
            case .junction(let junctionID, _):
                end = .junction(junctionID)
            case .wire(let index):
                end = .junction(HorizontalSchematicWireTool.splitWire(at: index, point: point, in: &sheet))
            case .nothing:
                end = .junction(HorizontalSchematicWireTool.newJunction(at: point, netID: netID, in: &sheet))
            }
            let start = anchorEndpoint ?? .junction(HorizontalSchematicWireTool.newJunction(at: anchor, netID: netID, in: &sheet))
            let added = HorizontalSchematicWireTool.layWire(from: anchor, start: start, to: point, end: end, bend: bend, netID: netID, in: &sheet)
            segmentCount += added.count
            hasChanges = true
            // What the wire reached puts it on a net, and a pin it reached
            // first on a new one, as Horizon gives a floating pin a net.
            sheet.spreadNets(touching: Set(added.flatMap { [key($0.from), key($0.to)] }))
            if case .nothing = target {
                self.anchor = point
                anchorEndpoint = end
                netID = added.last.flatMap { line in sheet.netLines.first { $0.id == line.id }?.netID } ?? netID
            } else {
                restart()
            }
        }

        /// Horizon's `restart`: the wire ended, and the next click starts a
        /// new one.
        mutating func restart() {
            anchor = nil
            anchorEndpoint = nil
            startPin = nil
            netID = nil
        }
    }

    /// A junction of the wire's own, where it starts or turns on nothing.
    static func newJunction(at point: HorizontalPoint, netID: String?, in sheet: inout HorizontalSchematicSheet) -> String {
        let junctionID = UUID().uuidString.lowercased()
        sheet.junctions[junctionID] = point
        if let netID {
            sheet.junctionNetIDs[junctionID] = netID
        }
        return junctionID
    }
}
