import Foundation
import HorizontalProjectIO

/// Where the refdes of one of the board's components is kept. The board is
/// made from the flattened design, so its component is either a component
/// of the top block, which holds its own refdes, or a part of a block
/// instance, whose refdes Horizon keeps in the top block's instance mapping
/// and never in the block the part is drawn in.
enum HorizontalBoardRefdesTarget: Equatable {
    /// A component of the top block, by its uuid.
    case topBlock(component: String)
    /// A part of a block instance: the component of `block` it is, and the
    /// instances, top down, that lead to it.
    case instance(block: String, path: [String], component: String)

    /// The `set_refdes` operation that gives an instance's part `refdes`,
    /// and the block it is run on; nil for a top block component, whose
    /// refdes is the block's own.
    func instanceOperation(settingRefdes refdes: String) -> (operation: JSONDictionary, block: String)? {
        guard case .instance(let block, let path, let component) = self else {
            return nil
        }
        return (["op": "set_refdes", "component": component, "refdes": refdes, "instance": path.joined(separator: "/")], block)
    }
}

extension HorizontalProject {
    /// Where the refdes of the board component `flatID` is kept: the flat
    /// uuid a package names its component by. Nil for one the flattened
    /// design does not have, which no block's file is to be given.
    func boardRefdesTarget(forComponent flatID: String) -> HorizontalBoardRefdesTarget? {
        let id = flatID.lowercased()
        guard let flattened = flattenedBlock else {
            // No block uses another: the board's components are the top block's.
            return .topBlock(component: id)
        }
        guard let path = flattened.componentPaths[id], let component = path.last else {
            return nil
        }
        guard path.count > 1 else {
            return .topBlock(component: component)
        }
        guard let block = flattened.componentBlocks[id] else {
            return nil
        }
        return .instance(block: block, path: Array(path.dropLast()), component: component)
    }
}
