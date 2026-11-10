import Foundation

/// Horizon's differential pairs: two nets of a block paired, so the board
/// can route, tune and check them together. The block file says it once, on
/// the primary: its `diffpair` names the secondary (Net::serialize writes it
/// only for a primary), and the secondary learns its partner as the block
/// loads (Block::update_diffpairs). A `diffpair` that names no net of the
/// block, or the null uuid, pairs nothing, and Horizon drops it at its next
/// save.
enum HorizontalDiffpairs {
    /// One net's side of a pair.
    struct Pairing: Hashable, Sendable {
        /// The other net, lowercased.
        var partnerID: String
        /// Whether this net is the one the file names the pair on.
        var isPrimary: Bool
    }

    private static let nullUUID = "00000000-0000-0000-0000-000000000000"

    /// The width Horizon draws a pair's schematic wires at, 0.2 mm, where
    /// other wires are hairlines.
    static let schematicLineWidth: Double = 200_000

    /// Every paired net's partner, by lowercased net id, from a block's
    /// `nets`, as Block::update_diffpairs works them out: in uuid order, each
    /// net whose `diffpair` names a net of the block is a primary, and points
    /// its partner back at itself. A file Horizon wrote holds one primary per
    /// pair; where two name the same net the later in uuid order has it, as
    /// in Horizon.
    static func resolve(_ nets: [String: JSONDictionary]) -> [String: Pairing] {
        let ids = nets.keys.map { $0.lowercased() }.sorted()
        let known = Set(ids)
        var pointer = [String: String]()
        var primary = Set<String>()
        for (key, net) in nets {
            if let target = partnerReference(in: net) {
                pointer[key.lowercased()] = target
                primary.insert(key.lowercased())
            }
        }
        for id in ids where primary.contains(id) {
            if let target = pointer[id], known.contains(target) {
                pointer[target] = id
            } else {
                pointer[id] = nil
                primary.remove(id)
            }
        }
        var result = [String: Pairing]()
        for (id, partner) in pointer where partner != id && known.contains(partner) {
            result[id] = Pairing(partnerID: partner, isPrimary: primary.contains(id))
        }
        return result
    }

    /// The same for a block file's whole JSON.
    static func resolve(block: JSONDictionary) -> [String: Pairing] {
        resolve(block.dictionaryMap("nets"))
    }

    /// `details` with each net's pairing from `nets`, the block they were read
    /// from; a net in no pair has none.
    static func annotate(_ details: inout [String: HorizontalNetDetails], nets: [String: JSONDictionary]) {
        let pairings = resolve(nets)
        for key in Array(details.keys) {
            let pairing = pairings[key.lowercased()]
            details[key]?.diffpairID = pairing?.partnerID
            details[key]?.isDiffpairPrimary = pairing?.isPrimary ?? false
        }
    }

    /// The nets in a pair, from details already annotated.
    static func pairedNetIDs(_ details: [String: HorizontalNetDetails]) -> Set<String> {
        Set(details.compactMap { key, detail in detail.diffpairID == nil ? nil : key.lowercased() })
    }

    /// Why a pairing can't be made.
    enum PairingError: Error, Equatable, LocalizedError {
        case sameNet(String)
        case unknownNet(String)
        /// `net` is in a pair with `partner` already.
        case alreadyPaired(net: String, partner: String)

        var errorDescription: String? {
            switch self {
            case .sameNet: "A net can't be its own differential pair."
            case .unknownNet(let net): "No net \(net)."
            case .alreadyPaired(let net, let partner): "\(net) is already in a differential pair with \(partner); clear it first."
            }
        }
    }

    /// Pairs `primary` with `secondary` in a block's `nets`, Horizon's Set
    /// Diff Pair: `diffpair` on the primary names the secondary. Two nets
    /// already paired with each other take the roles asked for; a net paired
    /// with any other is refused, as Horizon refuses it, until that pair is
    /// cleared. Returns whether the file changed.
    @discardableResult
    static func pair(_ primary: String, with secondary: String, in nets: inout JSONDictionary) throws -> Bool {
        guard let primaryKey = key(for: primary, in: nets) else { throw PairingError.unknownNet(primary) }
        guard let secondaryKey = key(for: secondary, in: nets) else { throw PairingError.unknownNet(secondary) }
        let primaryID = primaryKey.lowercased(), secondaryID = secondaryKey.lowercased()
        guard primaryID != secondaryID else { throw PairingError.sameNet(primaryID) }
        let pairings = resolve(nets.compactMapValues { $0 as? JSONDictionary })
        if let current = pairings[primaryID], current.partnerID != secondaryID {
            throw PairingError.alreadyPaired(net: name(primaryKey, in: nets), partner: name(current.partnerID, in: nets))
        }
        if let current = pairings[secondaryID], current.partnerID != primaryID {
            throw PairingError.alreadyPaired(net: name(secondaryKey, in: nets), partner: name(current.partnerID, in: nets))
        }
        if pairings[primaryID] == Pairing(partnerID: secondaryID, isPrimary: true),
           (nets[secondaryKey] as? JSONDictionary)?["diffpair"] == nil {
            return false
        }
        // The roles swap where the secondary was the primary.
        var secondaryJSON = nets[secondaryKey] as? JSONDictionary ?? [:]
        secondaryJSON.removeValue(forKey: "diffpair")
        nets[secondaryKey] = secondaryJSON
        var primaryJSON = nets[primaryKey] as? JSONDictionary ?? [:]
        primaryJSON["diffpair"] = secondaryID
        nets[primaryKey] = primaryJSON
        return true
    }

    /// Takes `net` out of its pair, Horizon's Clear Diff Pair, from either
    /// side: the `diffpair` naming it, or its own. Any other `diffpair` that
    /// names it goes too, so none is left to pair it again. Returns the
    /// partner it had, or nil when it had none.
    @discardableResult
    static func unpair(_ net: String, in nets: inout JSONDictionary) -> String? {
        guard let netKey = key(for: net, in: nets) else { return nil }
        let netID = netKey.lowercased()
        let partner = resolve(nets.compactMapValues { $0 as? JSONDictionary })[netID]?.partnerID
        for (key, value) in nets {
            guard var json = value as? JSONDictionary, let reference = json.string("diffpair") else { continue }
            if key.lowercased() == netID || reference.lowercased() == netID {
                json.removeValue(forKey: "diffpair")
                nets[key] = json
            }
        }
        return partner
    }

    /// Drops every `diffpair` naming one of `removed`, as Horizon's next save
    /// would once those nets are gone.
    static func dropReferences(to removed: Set<String>, in nets: inout JSONDictionary) {
        let removed = Set(removed.map { $0.lowercased() })
        guard !removed.isEmpty else { return }
        for (key, value) in nets {
            guard var json = value as? JSONDictionary, let reference = json.string("diffpair"),
                  removed.contains(reference.lowercased()) else { continue }
            json.removeValue(forKey: "diffpair")
            nets[key] = json
        }
    }

    /// The partner a net's own JSON names, as Net's constructor reads it: a
    /// uuid that isn't the null one.
    private static func partnerReference(in net: JSONDictionary) -> String? {
        guard let reference = net.string("diffpair")?.lowercased(), !reference.isEmpty, reference != nullUUID else {
            return nil
        }
        return reference
    }

    private static func key(for id: String, in nets: JSONDictionary) -> String? {
        nets.keys.first { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    private static func name(_ id: String, in nets: JSONDictionary) -> String {
        let name = key(for: id, in: nets).flatMap { (nets[$0] as? JSONDictionary)?.string("name") } ?? ""
        return name.isEmpty ? String(id.lowercased().prefix(8)) : name
    }
}
