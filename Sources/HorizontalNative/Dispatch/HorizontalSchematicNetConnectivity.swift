import Foundation

/// Resolve a sheet's electrical graph by endpoint identity. Horizon files can
/// omit net fields on both wires and junctions; the block's pin connections,
/// power symbols and labels supply them. Conflicting or floating segments stay
/// unresolved. Coordinates alone never join separate junctions.
struct HorizontalSchematicNetConnectivity {
    private var netsByEndpoint: [String: String] = [:]

    static func endpointID(_ endpoint: JSONDictionary) -> String? {
        let identities = ["junc", "pin", "port", "bus_ripper"].compactMap { kind in
            endpoint.string(kind).map { "\(kind)/\($0.lowercased())" }
        }
        return identities.count == 1 ? identities[0] : nil
    }

    func net(at endpoint: JSONDictionary) -> String? {
        Self.endpointID(endpoint).flatMap { netsByEndpoint[$0] }
    }

    init(sheet: JSONDictionary, block: JSONDictionary, requiresKnownNet: Bool = true) {
        var neighbors = [String: Set<String>]()
        var seeds = [String: Set<String>]()
        var cachedWireNets = [String: Set<String>]()
        func seed(_ endpoint: JSONDictionary, _ net: String?) {
            guard let id = Self.endpointID(endpoint) else { return }
            if neighbors[id] == nil { neighbors[id] = [] }
            if let net, net != HorizontalProjectEditor.nullUUID {
                seeds[id, default: []].insert(net.lowercased())
            }
        }
        for (id, junction) in sheet.dictionaryMap("junctions") {
            seed(["junc": id], junction.string("net"))
        }
        let components = block.dictionaryMap("components")
        for (id, symbol) in sheet.dictionaryMap("symbols") {
            guard let component = symbol.string("component"), let gate = symbol.string("gate")?.lowercased() else { continue }
            for (path, connection) in components[component]?.dictionaryMap("connections") ?? [:] {
                let parts = path.lowercased().split(separator: "/")
                guard parts.count == 2, parts[0] == gate else { continue }
                seed(["pin": "\(id)/\(parts[1])"], connection.string("net"))
            }
        }
        let instances = block.dictionaryMap("block_instances")
        for (id, symbol) in sheet.dictionaryMap("block_symbols") {
            guard let instance = symbol.string("block_instance") else { continue }
            for (port, connection) in instances[instance]?.dictionaryMap("connections") ?? [:] {
                seed(["port": "\(id)/\(port)"], connection.string("net"))
            }
        }
        for (table, field) in [("net_labels", "last_net"), ("power_symbols", "net")] {
            for mark in sheet.dictionaryMap(table).values {
                if let junction = mark.string("junction") { seed(["junc": junction], mark.string(field)) }
            }
        }
        let buses = block.dictionaryMap("buses")
        for (id, ripper) in sheet.dictionaryMap("bus_rippers") {
            guard let bus = ripper.string("bus"), let member = ripper.string("member") else { continue }
            seed(["bus_ripper": id], buses[bus]?.dictionaryMap("members")[member]?.string("net"))
        }
        for line in sheet.dictionaryMap("net_lines").values {
            guard let from = line.dictionary("from"), let to = line.dictionary("to"),
                  let a = Self.endpointID(from), let b = Self.endpointID(to) else { continue }
            neighbors[a, default: []].insert(b)
            neighbors[b, default: []].insert(a)
            if let net = line.string("net"), net != HorizontalProjectEditor.nullUUID {
                cachedWireNets[a, default: []].insert(net.lowercased())
            }
        }
        let knownNets = Set(block.dictionaryMap("nets").keys.map { $0.lowercased() })
        var visited = Set<String>()
        for start in neighbors.keys where !visited.contains(start) {
            var pending = [start]
            var connected = Set<String>()
            var nets = Set<String>()
            var wireNets = Set<String>()
            visited.insert(start)
            while let id = pending.popLast() {
                connected.insert(id)
                nets.formUnion(seeds[id] ?? [])
                wireNets.formUnion(cachedWireNets[id] ?? [])
                for next in neighbors[id] ?? [] where visited.insert(next).inserted { pending.append(next) }
            }
            // Wire net fields are cached artwork metadata. Pin, junction and
            // label connectivity can change without updating those fields.
            if nets.isEmpty { nets = wireNets }
            guard nets.count == 1, let net = nets.first,
                  !requiresKnownNet || knownNets.contains(net) else { continue }
            for id in connected { netsByEndpoint[id] = net }
        }
    }
}
