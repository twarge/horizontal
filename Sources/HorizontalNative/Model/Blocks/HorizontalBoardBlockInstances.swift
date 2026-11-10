import Foundation

/// The design's block instances as the board sees them, for keeping the
/// instances of a block laid out alike (`HorizontalBlockLayoutMatch`).
/// Nothing in Horizon's files says which instance a board package belongs
/// to except its component's flat uuid, which the flattener makes from the
/// instance path; this index turns that back into instances and their
/// members, keyed by the path below the instance, so the same part of two
/// instances has the same key.
struct HorizontalBoardBlockInstances: Sendable {
    struct Instance: Hashable, Sendable {
        /// Its instance uuids top down, `/`-joined, lowercased.
        var path: String
        /// Its instances' refdes top down: `I1/S1`.
        var name: String
        var blockID: String
        /// Its components however deep, flat uuid by local path: the uuids
        /// below the instance, `/`-joined, the block component last.
        var members: [String: String]
    }

    static let empty = HorizontalBoardBlockInstances()

    /// Every instance, by path.
    private(set) var instances = [String: Instance]()
    /// Each block's name, for saying which block an instance is of.
    private(set) var blockNames = [String: String]()
    /// The instances of each block used more than once, in name order.
    private(set) var siblings = [String: [String]]()
    /// Each flat component's instances, innermost first.
    private(set) var componentInstances = [String: [String]]()
    /// The flat net a local net path stands for (`/`-joined, the net last).
    private(set) var netsByPath = [String: String]()
    /// Each flat net's local paths.
    private(set) var netPaths = [String: [[String]]]()

    private init() {}

    init(_ flattened: HorizontalFlattenedBlock) {
        for (path, blockID) in flattened.instanceBlocks {
            instances[path] = Instance(path: path, name: flattened.instanceNames[path] ?? path, blockID: blockID, members: [:])
        }
        blockNames = flattened.blockNames
        for (flatID, path) in flattened.componentPaths where path.count > 1 {
            var containing = [String]()
            for depth in (1..<path.count).reversed() {
                let instancePath = path[..<depth].joined(separator: "/")
                guard instances[instancePath] != nil else { continue }
                instances[instancePath]?.members[path[depth...].joined(separator: "/")] = flatID
                containing.append(instancePath)
            }
            componentInstances[flatID] = containing
        }
        let byBlock = Dictionary(grouping: instances.values, by: \.blockID)
        for (blockID, group) in byBlock where group.count > 1 {
            siblings[blockID] = group.sorted(by: Self.inOrder).map(\.path)
        }
        netPaths = flattened.netPaths
        for (flatNet, paths) in flattened.netPaths {
            for path in paths {
                netsByPath[path.joined(separator: "/")] = flatNet
            }
        }
    }

    var isEmpty: Bool {
        siblings.isEmpty
    }

    /// Instances in name order, natural (`I2` before `I10`), then by path.
    static func inOrder(_ lhs: Instance, _ rhs: Instance) -> Bool {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.path < rhs.path
        }
    }

    /// The innermost instance of a block used more than once that flat
    /// component `componentID` is a member of, and the instances of blocks
    /// used more than once around it, innermost first.
    func syncedInstances(of componentID: String) -> [Instance] {
        (componentInstances[componentID.lowercased()] ?? []).compactMap { path in
            guard let instance = instances[path], siblings[instance.blockID] != nil else { return nil }
            return instance
        }
    }

    /// The instance's sibling instances, itself left out, in name order.
    func siblings(of instance: Instance) -> [Instance] {
        (siblings[instance.blockID] ?? []).compactMap { $0 == instance.path ? nil : instances[$0] }
    }

    /// The net local to `instance` that flat net `netID` is there, `/`-joined
    /// below the instance, nil when it isn't one of the instance's (a power
    /// net, or another instance's).
    func localNet(_ netID: String, in instance: Instance) -> String? {
        let prefix = instance.path.split(separator: "/").map(String.init)
        return (netPaths[netID.lowercased()] ?? []).lazy
            .filter { $0.count > prefix.count && Array($0[..<prefix.count]) == prefix }
            .map { $0[prefix.count...].joined(separator: "/") }
            .min()
    }

    /// The flat net that `instance`'s local net `local` is.
    func flatNet(_ local: String, in instance: Instance) -> String? {
        netsByPath[instance.path + "/" + local]
    }

    /// Whether every one of flat net `netID`'s local paths is inside
    /// `instance`: a net of the instance's own, which nothing outside it is on.
    func isOwnNet(_ netID: String, of instance: Instance) -> Bool {
        let prefix = instance.path.split(separator: "/").map(String.init)
        guard let paths = netPaths[netID.lowercased()], !paths.isEmpty else { return false }
        return paths.allSatisfy { $0.count > prefix.count && Array($0[..<prefix.count]) == prefix }
    }
}
