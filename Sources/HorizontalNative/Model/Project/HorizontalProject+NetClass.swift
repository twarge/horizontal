import Foundation
import HorizontalProjectIO

/// Why a net's class, set in an inspector, could not be kept.
enum HorizontalNetClassChangeError: LocalizedError, Equatable {
    /// The net is inside a block instance: the top block's file has no such
    /// net, and its class is the one its own block gives it.
    case netOfBlockInstance
    /// The project names no file for its top block.
    case noBlockFile

    var errorDescription: String? {
        switch self {
        case .netOfBlockInstance:
            "This net is inside a block instance, so its class is its block's. Set it on that block's sheet."
        case .noBlockFile:
            "The project has no block file to keep the class in."
        }
    }
}

/// A net's class as an inspector sets it, on the board or on a sheet.
///
/// The class is the block's (`nets[...]["net_class"]`): the board file holds
/// none, and every sheet carries a copy of the block's nets that it writes
/// back with its next edit. So a class set anywhere goes to the block file
/// and to every copy the project holds, or the next sheet edit, reload or
/// netlist sync puts the old one back.
extension HorizontalProject {
    /// The file that holds the top block's nets, and with them their classes.
    var topBlockURL: URL? {
        blockFilename.map { baseURL.appendingPathComponent($0) }
    }

    /// Whether a board net is one of the top block's own. In a project with
    /// block instances a net inside one is its block's, and the top block's
    /// file has nothing by its id.
    func topBlockHoldsNet(_ netID: String) -> Bool {
        guard let flattenedBlock, flattenedBlock.isHierarchical else {
            return true
        }
        return flattenedBlock.netPaths[netID.lowercased()]?.contains { $0.count == 1 } ?? false
    }

    /// Puts the top block's net in a class, or in none: in the block file in
    /// `archive` first, then in the schematic's, its sheets' and the board's
    /// copies of the net. A change that can't be written changes nothing.
    mutating func putNet(
        _ netID: String,
        inClass netClassID: String?,
        archive: inout HorizontalProjectArchive
    ) throws {
        let netID = netID.lowercased()
        let classID = netClassID?.lowercased()
        guard topBlockHoldsNet(netID) else {
            throw HorizontalNetClassChangeError.netOfBlockInstance
        }
        guard let blockURL = topBlockURL else {
            throw HorizontalNetClassChangeError.noBlockFile
        }
        try HorizontalProjectJSONApplicator.apply(
            netClassID: classID,
            forNetID: netID,
            blockURL: blockURL,
            in: self,
            to: &archive
        )

        let className = classID.flatMap { id in
            schematic?.netClasses.first { $0.id.lowercased() == id }?.name
        }
        // Only where the net already is: a copy that lacks it writes nothing
        // of it, and one made up here would write its made-up name.
        func reclass(_ details: inout [String: HorizontalNetDetails]) {
            guard var detail = details[netID] else {
                return
            }
            detail.netClassID = classID
            detail.netClassName = className
            details[netID] = detail
        }
        func reclassNets(of schematic: inout HorizontalSchematic) {
            reclass(&schematic.netDetails)
            for index in schematic.sheets.indices {
                reclass(&schematic.sheets[index].netDetails)
            }
        }

        let topSchematicURL = schematic?.url.standardizedFileURL
        if var top = schematic {
            reclassNets(of: &top)
            schematic = top
        }
        for index in schematics.indices
            where schematics[index].block.isTop || schematics[index].schematic.url.standardizedFileURL == topSchematicURL {
            reclassNets(of: &schematics[index].schematic)
        }
        if var board {
            reclass(&board.netDetails)
            self.board = board
        }
    }
}
