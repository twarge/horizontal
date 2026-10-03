import Foundation

/// Names a batch gives the things it makes. An op whose id is the id of a new
/// thing — a junction, a symbol instance, a wire, a component — may give a
/// short name such as "j1" instead of a UUID, and later ops in the batch may
/// use that name wherever they refer to that kind of thing. Before anything
/// is applied, each name becomes a UUID everywhere it means that thing, so the
/// editor only ever sees UUIDs. The UUID comes from the revision and the name,
/// so a dry run and the commit that replays it mint the same ones, and the
/// normalized ops a dry run returns are what a commit replays.
///
/// The first op to give a name as its id defines it; every later use, as an
/// id or a reference, means the same thing. A name only stands for its own
/// kind: a junction called "GND" leaves every net field alone. A UUID is never
/// a name, and a name no earlier op defined is passed on as it is.
enum HorizontalEditHandles {
    enum Kind: String {
        case component, net, bus, busMember = "bus_member", netTie = "net_tie", netClass = "net_class"
        case symbol, netLine = "net_line", junction, blockInstance = "block_instance"
    }

    /// The ops whose id names the thing they make.
    static let defining: [String: Kind] = [
        "ensure_component": .component, "ensure_net": .net, "add_bus": .bus, "add_bus_member": .busMember,
        "add_net_tie": .netTie, "add_net_class": .netClass, "place_symbol": .symbol, "draw_net_line": .netLine,
        "place_junction": .junction, "add_block_instance": .blockInstance
    ]

    /// Fields that name an existing thing of a kind, on any op.
    static let references: [String: Kind] = [
        "component": .component, "to_component": .component,
        "net": .net, "primary": .net, "secondary": .net,
        "bus": .bus, "member": .busMember, "net_tie": .netTie, "net_class": .netClass,
        "symbol_instance": .symbol, "line": .netLine, "junction": .junction, "instance": .blockInstance
    ]

    /// Fields inside a schematic wire end. Only the wire ops have those: a
    /// track's ends name board junctions, which a schematic junction is not.
    static let endpointReferences: [String: Kind] = ["component": .component, "symbol": .symbol, "junction": .junction]
    static let endpointOps: Set<String> = ["draw_net_line", "set_net_line_endpoint"]
    static let endpointKeys = ["from", "to", "endpoint"]

    private static let namespace = UUID(uuidString: "3b9d6f0e-8a1c-4e52-b7d4-5f2a9c0e6d13")!

    /// The ops with every name replaced by its UUID, and the names defined,
    /// each with the UUID it became.
    static func resolve(_ ops: [Any], revision: String) throws -> (ops: [Any], handles: [String: String]) {
        var defined = [Kind: [String: String]]()
        var handles = [String: String]()
        func uuid(_ value: Any?, _ kind: Kind) -> String? {
            guard let name = value as? String, UUID(uuidString: name) == nil else { return nil }
            return defined[kind]?[name]
        }
        let resolved = try ops.enumerated().map { index, raw -> Any in
            guard var op = raw as? JSONDictionary else { return raw }
            let name = op.string("op") ?? ""
            for (key, kind) in references {
                if let id = uuid(op[key], kind) { op[key] = id }
            }
            if endpointOps.contains(name) {
                for key in endpointKeys {
                    guard var end = op[key] as? JSONDictionary else { continue }
                    for (field, kind) in endpointReferences {
                        if let id = uuid(end[field], kind) { end[field] = id }
                    }
                    op[key] = end
                }
            }
            if let kind = defining[name], let handle = op["id"] as? String, UUID(uuidString: handle) == nil {
                guard !handle.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw HorizontalDispatchError.invalidParams("id must be a UUID or a name for later ops to use.")
                        .inOperation(index, name)
                }
                if let id = defined[kind]?[handle] {
                    op["id"] = id
                } else {
                    if let other = handles[handle] {
                        throw HorizontalDispatchError.invalidParams(
                            "\"\(handle)\" already names \(other) in this batch; give each new thing its own name."
                        ).inOperation(index, name)
                    }
                    let id = UUID.horizonUUID5(namespace: namespace, name: Array("\(revision)\n\(kind.rawValue)\n\(handle)".utf8))
                        .uuidString.lowercased()
                    defined[kind, default: [:]][handle] = id
                    handles[handle] = id
                    op["id"] = id
                }
            }
            return op
        }
        return (resolved, handles)
    }
}
