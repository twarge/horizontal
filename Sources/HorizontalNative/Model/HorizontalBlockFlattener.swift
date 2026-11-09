import Foundation

/// Horizon's `Block::flatten`: the top block with every block instance in
/// it, however deep, expanded into components and nets of its own — what the
/// board, the BOM and the netlist are made from.
///
/// An instance's component gets the uuid Horizon derives from its instance
/// path (`uuid_vec_flatten`), so the packages Horizon placed for it on the
/// board name it, and the refdes and no-populate its instance mapping gives
/// it. Each of an instance's nets becomes a net of its own, named for the
/// path (`I1/Out`), except a port wired to a net outside, which is that net,
/// and a power net, which is the top block's. What comes out is a block file
/// in Horizon's format, so whatever reads a block reads it.
///
/// Sendable by hand, as the block symbol models are: made once at load and
/// never mutated in place.
struct HorizontalFlattenedBlock: @unchecked Sendable {
    /// The flattened block, as a block file would hold it.
    var json: JSONDictionary
    /// Each component's instance path, its own uuid last: `[I1, C3]`. A top
    /// block component's path is its uuid alone.
    var componentPaths: [String: [String]]
    /// The block each flat component is a component of, by flat uuid.
    var componentBlocks: [String: String] = [:]
    /// The instance paths each net stands for, its own uuid last.
    var netPaths: [String: [[String]]]
    /// Nets that are a port marked not connected in some instance.
    var noConnectNets: Set<String>
    /// Each instance path's own refdes for its block's components, by path
    /// (`/`-joined instance uuids) and component: the top block's mappings.
    var instanceRefdes: [String: [String: String]] = [:]
    /// Each instance path's do-not-populate for the components its mapping
    /// names, by path and component. A component the mapping leaves out
    /// keeps its own, as `Block::get_component_info` gives it.
    var instanceNoPopulate: [String: [String: Bool]] = [:]
    /// The block each instance is of, by instance path (`/`-joined instance
    /// uuids, however deep).
    var instanceBlocks: [String: String] = [:]
    /// Each instance's name, its instances' refdes top down (`I1/I3`), by
    /// instance path: `instance_path_to_string`.
    var instanceNames: [String: String] = [:]
    /// Each instanced block's name, by block uuid.
    var blockNames: [String: String] = [:]
    /// The instances as the board sees them, made once with the rest.
    var boardInstances = HorizontalBoardBlockInstances.empty

    /// Whether anything was expanded: false for a project without instances.
    var isHierarchical: Bool {
        componentPaths.values.contains { $0.count > 1 }
    }

    /// The flattened components, by flat uuid: each one's refdes and
    /// no-populate for its instance, and the component of its block it is.
    var instances: [(flatID: String, componentID: String, refdes: String, noPopulate: Bool)] {
        json.dictionaryMap("components").compactMap { id, component in
            guard let path = componentPaths[id.lowercased()], let componentID = path.last else { return nil }
            return (id.lowercased(), componentID, component.string("refdes") ?? "", component.bool("nopopulate") ?? false)
        }
    }

    /// `componentIDs` as a block's sheets name parts: with each flat (board)
    /// id that is an instance of a block's component, that component's own
    /// id, the one its symbol on the block's sheet has. What a part picked or
    /// spotlit on the board is in the schematic, whichever instance it is.
    func blockComponentIDs(for componentIDs: Set<String>) -> Set<String> {
        var ids = componentIDs
        for id in componentIDs {
            if let path = componentPaths[id.lowercased()], path.count > 1, let own = path.last {
                ids.insert(own)
            }
        }
        return ids
    }

    /// `componentIDs` as the board names parts: with each block component's
    /// id, the flat id of every instance of it, which the board's packages
    /// have. What a symbol picked or spotlit on a block's sheet is on the
    /// board: every instance's package. A flat id is left as it is, and
    /// brings in no other instance.
    func boardComponentIDs(for componentIDs: Set<String>) -> Set<String> {
        let wanted = Set(componentIDs.map { $0.lowercased() })
        var ids = componentIDs
        for (flatID, path) in componentPaths where path.count > 1 {
            if let own = path.last, wanted.contains(own.lowercased()) {
                ids.insert(flatID)
            }
        }
        return ids
    }

    /// The flat uuids of block `blockID`'s components `componentIDs`, one for
    /// each instance of the block however deep: what the board names their
    /// packages by.
    func flatIDs(of componentIDs: Set<String>, inBlock blockID: String) -> [String] {
        let wanted = Set(componentIDs.map { $0.lowercased() })
        return componentBlocks.compactMap { flatID, block in
            guard block == blockID.lowercased(), let id = componentPaths[flatID]?.last, wanted.contains(id) else { return nil }
            return flatID
        }.sorted()
    }
}

enum HorizontalBlockFlattener {
    /// `uuid_vec_flatten`'s namespace.
    static let namespace = UUID(uuidString: "822e3f74-6d4b-4b07-807a-dc56415c1a9d")!
    /// Horizon's `max_instance_path_len`.
    static let maximumDepth = 10

    /// `uuid_vec_flatten`: a path of one is that uuid; a longer one, UUID5 of
    /// its uuids' bytes end to end.
    static func flattenedID(_ path: [String]) -> String {
        guard path.count > 1 else {
            return path.first?.lowercased() ?? ""
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(path.count * 16)
        for id in path {
            guard let uuid = UUID(uuidString: id) else {
                return path.joined(separator: "/").lowercased()
            }
            withUnsafeBytes(of: uuid.uuid) { bytes.append(contentsOf: $0) }
        }
        return UUID.horizonUUID5(namespace: namespace, name: bytes).uuidString.lowercased()
    }

    /// The top block flattened, with `blocks` the project's block files by
    /// uuid (the top's among them). Instances of a block missing from
    /// `blocks` are left out.
    static func flatten(top: JSONDictionary, blocks: [String: JSONDictionary]) -> HorizontalFlattenedBlock {
        var context = Context(top: top, blocks: blocks.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value })
        context.flat = top
        context.flat["block_instances"] = JSONDictionary()
        context.flat["block_instance_mappings"] = JSONDictionary()
        let topID = top.string("uuid")?.lowercased() ?? ""
        for id in top.dictionaryMap("components").keys {
            context.componentPaths[id.lowercased()] = [id.lowercased()]
            context.componentBlocks[id.lowercased()] = topID
        }
        for id in top.dictionaryMap("nets").keys {
            context.netMap[[id.lowercased()]] = id.lowercased()
        }
        for (id, instance) in sorted(top.dictionaryMap("block_instances")) {
            context.mapPorts(of: instance, id: id, path: [])
            if let blockID = instance.string("block")?.lowercased(), let block = context.blocks[blockID] {
                context.visit(block, id: blockID, path: [id.lowercased()])
            }
        }

        var netPaths = [String: [[String]]]()
        for (path, netID) in context.netMap.sorted(by: { $0.key.joined() < $1.key.joined() }) {
            netPaths[netID, default: []].append(path)
        }
        let noConnect = Set(context.noConnectPaths.compactMap { context.netMap[$0] })
        if !noConnect.isEmpty {
            var nets = context.flat["nets"] as? JSONDictionary ?? [:]
            for netID in noConnect {
                if var net = nets[netID] as? JSONDictionary {
                    net["is_nc"] = true
                    nets[netID] = net
                }
            }
            context.flat["nets"] = nets
        }
        let instanceRefdes = top.dictionaryMap("block_instance_mappings").reduce(into: [String: [String: String]]()) { result, item in
            result[item.key.lowercased()] = item.value.dictionaryMap("components").reduce(into: [String: String]()) {
                if let refdes = $1.value.string("refdes") { $0[$1.key.lowercased()] = refdes }
            }
        }
        let instanceNoPopulate = top.dictionaryMap("block_instance_mappings").reduce(into: [String: [String: Bool]]()) { result, item in
            result[item.key.lowercased()] = item.value.dictionaryMap("components").reduce(into: [String: Bool]()) {
                $0[$1.key.lowercased()] = $1.value.bool("nopopulate") ?? false
            }
        }
        var flattened = HorizontalFlattenedBlock(
            json: context.flat, componentPaths: context.componentPaths,
            componentBlocks: context.componentBlocks,
            netPaths: netPaths, noConnectNets: noConnect, instanceRefdes: instanceRefdes,
            instanceNoPopulate: instanceNoPopulate, instanceBlocks: context.instanceBlocks,
            instanceNames: context.instanceNames,
            blockNames: Set(context.instanceBlocks.values).reduce(into: [String: String]()) { names, blockID in
                names[blockID] = context.blocks[blockID]?.string("name")
            }
        )
        flattened.boardInstances = HorizontalBoardBlockInstances(flattened)
        return flattened
    }

    /// The project's top block flattened, from the block files under
    /// `baseURL`; nil when the top block uses no other block, which leaves it
    /// as it is.
    static func flatten(blocks: [HorizontalProjectBlock], baseURL: URL) -> HorizontalFlattenedBlock? {
        var files = [String: JSONDictionary]()
        for block in blocks {
            guard let filename = block.blockFilename, !filename.isEmpty,
                  let json = try? JSONHelper.loadDictionary(from: baseURL.appendingPathComponent(filename)) else { continue }
            files[block.uuid.lowercased()] = json
        }
        guard let top = blocks.first(where: \.isTop).flatMap({ files[$0.uuid.lowercased()] }),
              !top.dictionaryMap("block_instances").isEmpty else {
            return nil
        }
        return flatten(top: top, blocks: files)
    }

    private static func sorted(_ map: [String: JSONDictionary]) -> [(key: String, value: JSONDictionary)] {
        map.sorted { $0.key.lowercased() < $1.key.lowercased() }
    }

    private struct Context {
        let top: JSONDictionary
        let blocks: [String: JSONDictionary]
        var flat = JSONDictionary()
        /// An instance path to a net, its uuid last, → the flat net it is.
        var netMap = [[String]: String]()
        var noConnectPaths = Set<[String]>()
        var componentPaths = [String: [String]]()
        var componentBlocks = [String: String]()
        var instanceBlocks = [String: String]()
        var instanceNames = [String: String]()

        /// `update_net_map_for_instance`: each wired port of an instance is the
        /// net it is wired to, here; an NC port is noted.
        mutating func mapPorts(of instance: JSONDictionary, id: String, path: [String]) {
            for (port, connection) in instance.dictionaryMap("connections") {
                let instanceNet = path + [id.lowercased(), port.lowercased()]
                if let net = connection.string("net")?.lowercased() {
                    if let flatNet = netMap[path + [net]], netMap[instanceNet] == nil {
                        netMap[instanceNet] = flatNet
                    }
                } else {
                    noConnectPaths.insert(instanceNet)
                }
            }
        }

        /// `instance_path_to_string`: the instances' refdes, top down.
        func pathName(_ path: [String]) -> String {
            var names = [String]()
            var block = top
            for id in path {
                guard let instance = block.dictionaryMap("block_instances").first(where: { $0.key.lowercased() == id })?.value else {
                    break
                }
                names.append(instance.string("refdes") ?? "")
                block = instance.string("block").flatMap { blocks[$0.lowercased()] } ?? [:]
            }
            return names.joined(separator: "/")
        }

        /// `Block::get_net_name`: the net's name, or for an unnamed one the
        /// refdes of what is on it.
        static func netName(_ netID: String, in block: JSONDictionary) -> String {
            if let name = block.dictionaryMap("nets").first(where: { $0.key.lowercased() == netID })?.value.string("name"), !name.isEmpty {
                return name
            }
            var refdes = [String]()
            for (_, component) in HorizontalBlockFlattener.sorted(block.dictionaryMap("components")) {
                for (_, connection) in HorizontalBlockFlattener.sorted(component.dictionaryMap("connections"))
                    where connection.string("net")?.lowercased() == netID {
                    refdes.append(component.string("refdes") ?? "")
                }
            }
            return refdes.joined(separator: ", ")
        }

        /// The instance mapping's refdes and no-populate for a component, as
        /// `Block::get_component_info` gives them.
        func componentInfo(_ componentID: String, path: [String], component: JSONDictionary) -> (refdes: String, noPopulate: Bool) {
            let mappings = top.dictionaryMap("block_instance_mappings")
            let key = path.joined(separator: "/")
            if let mapping = mappings.first(where: { $0.key.lowercased() == key })?.value,
               let info = mapping.dictionaryMap("components").first(where: { $0.key.lowercased() == componentID })?.value {
                return (info.string("refdes") ?? component.string("refdes") ?? "", info.bool("nopopulate") ?? false)
            }
            return (component.string("refdes") ?? "", component.bool("nopopulate") ?? false)
        }

        mutating func visit(_ block: JSONDictionary, id blockID: String, path: [String]) {
            guard path.count < HorizontalBlockFlattener.maximumDepth else { return }
            let name = pathName(path)
            instanceBlocks[path.joined(separator: "/")] = blockID
            instanceNames[path.joined(separator: "/")] = name
            var nets = flat["nets"] as? JSONDictionary ?? [:]
            let netClasses = flat["net_classes"] as? JSONDictionary ?? [:]
            let defaultClass = flat["net_class_default"]
            var diffpairs = [(netID: String, partner: String)]()
            let pairings = HorizontalDiffpairs.resolve(block: block)
            for (rawID, net) in HorizontalBlockFlattener.sorted(block.dictionaryMap("nets")) {
                let id = rawID.lowercased()
                let localPath = path + [id]
                if net.bool("is_power") == true {
                    // Power nets are the top block's, the same in every block.
                    if netMap[localPath] == nil { netMap[localPath] = id }
                    if nets[id] == nil { nets[id] = net }
                    continue
                }
                guard netMap[localPath] == nil else {
                    // A port, wired to the net outside it.
                    continue
                }
                let flatID = HorizontalBlockFlattener.flattenedID(localPath)
                netMap[localPath] = flatID
                var flatNet = net
                flatNet["name"] = name + "/" + Self.netName(id, in: block)
                flatNet["is_port"] = false
                // The pair is the instance's own: its primary names its
                // partner's flat net once both are in (below).
                flatNet.removeValue(forKey: "diffpair")
                if let netClass = net.string("net_class"), netClasses.keys.contains(where: { $0.lowercased() == netClass.lowercased() }) {
                    flatNet["net_class"] = netClass
                } else {
                    flatNet["net_class"] = defaultClass
                }
                nets[flatID] = flatNet
                // A primary is the net whose `diffpair` names a net of the
                // block, as Horizon's Net reads it; the file has no other mark.
                if let pairing = pairings[id], pairing.isPrimary {
                    diffpairs.append((flatID, pairing.partnerID))
                }
            }
            for pair in diffpairs {
                guard let partner = netMap[path + [pair.partner]], var net = nets[pair.netID] as? JSONDictionary else { continue }
                net["diffpair"] = partner
                nets[pair.netID] = net
            }
            flat["nets"] = nets

            var components = flat["components"] as? JSONDictionary ?? [:]
            for (rawID, component) in HorizontalBlockFlattener.sorted(block.dictionaryMap("components")) {
                let id = rawID.lowercased()
                let href = path + [id]
                let flatID = HorizontalBlockFlattener.flattenedID(href)
                var flatComponent = component
                let info = componentInfo(id, path: path, component: component)
                flatComponent["refdes"] = info.refdes
                flatComponent["nopopulate"] = info.noPopulate
                if let group = component.string("group"), group != HorizontalProjectEditor.nullUUID {
                    flatComponent["group"] = HorizontalBlockFlattener.flattenedID(path + [group.lowercased()])
                }
                var connections = JSONDictionary()
                for (pin, connection) in component.dictionaryMap("connections") {
                    var flatConnection = connection
                    if let net = connection.string("net")?.lowercased() {
                        flatConnection["net"] = netMap[path + [net]] ?? NSNull()
                    }
                    connections[pin] = flatConnection
                }
                flatComponent["connections"] = connections
                components[flatID] = flatComponent
                componentPaths[flatID] = href
                componentBlocks[flatID] = blockID
            }
            flat["components"] = components

            if !block.dictionaryMap("net_ties").isEmpty {
                var ties = flat["net_ties"] as? JSONDictionary ?? [:]
                for (rawID, tie) in HorizontalBlockFlattener.sorted(block.dictionaryMap("net_ties")) {
                    var flatTie = tie
                    for key in ["net_primary", "net_secondary"] {
                        if let net = tie.string(key)?.lowercased() { flatTie[key] = netMap[path + [net]] ?? NSNull() }
                    }
                    ties[HorizontalBlockFlattener.flattenedID(path + [rawID.lowercased()])] = flatTie
                }
                flat["net_ties"] = ties
            }

            var groupNames = flat["group_names"] as? JSONDictionary ?? [:]
            for (id, groupName) in (block["group_names"] as? JSONDictionary ?? [:]) {
                let flatID = HorizontalBlockFlattener.flattenedID(path + [id.lowercased()])
                if groupNames[flatID] == nil { groupNames[flatID] = name + "/" + ((groupName as? String) ?? "") }
            }
            flat["group_names"] = groupNames
            // Tags keep their uuids, so a tag matches across instances.
            var tagNames = flat["tag_names"] as? JSONDictionary ?? [:]
            for (id, tagName) in (block["tag_names"] as? JSONDictionary ?? [:]) where tagNames[id] == nil {
                tagNames[id] = name + "/" + ((tagName as? String) ?? "")
            }
            flat["tag_names"] = tagNames

            for (id, instance) in HorizontalBlockFlattener.sorted(block.dictionaryMap("block_instances")) {
                mapPorts(of: instance, id: id, path: path)
                if let childID = instance.string("block")?.lowercased(), let child = blocks[childID] {
                    visit(child, id: childID, path: path + [id.lowercased()])
                }
            }
        }
    }
}
