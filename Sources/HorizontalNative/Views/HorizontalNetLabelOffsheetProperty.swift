import Foundation

/// A net label's Off-sheet references row, Horizon's `offsheet_refs`: the
/// label lists the other sheets its net is labelled on, `[2,3]`, after its
/// name. The change is the automation channel's `place_net_label` on the
/// label's id, so the reload that redraws the label is one undo step.
enum HorizontalNetLabelOffsheetProperty {
    static let id = "offsheetRefs"
    static let label = "Off-sheet references"

    static func property(for netLabel: HorizontalSchematicNetLabel, editable: Bool) -> HorizontalSelectionProperty {
        editable
            ? HorizontalSelectionProperty(id: id, label: label, editor: .bool, value: .bool(netLabel.showsOffsheetRefs))
            : HorizontalSelectionProperty(id: id, label: label, editor: .readOnly, value: .readOnly(netLabel.showsOffsheetRefs ? "Shown" : "Hidden"))
    }

    /// The edit turning the references on (`shown`) or off for `labels`,
    /// with its undo title; nil when none of them would change.
    static func edit(shown: Bool, labels: [HorizontalSchematicNetLabel]) -> (ops: [JSONDictionary], actionName: String)? {
        let ops: [JSONDictionary] = labels
            .filter { $0.showsOffsheetRefs != shown }
            .map { ["op": "place_net_label", "id": $0.id.lowercased(), "offsheet_refs": shown] }
        return ops.isEmpty ? nil : (ops, shown ? "Show Off-sheet References" : "Hide Off-sheet References")
    }
}
