import Foundation

/// What the plane editor edits: Horizon's plane dialog — the net, the fill
/// order, whether the pour settings come from the rules, and the settings
/// themselves for when they do not.
struct HorizontalPlaneEditorDraft: Equatable {
    var netID: String?
    var priority: Int
    var fromRules: Bool
    var settings: HorizontalPlaneSettings

    init(netID: String?, priority: Int = 0, fromRules: Bool = true, settings: HorizontalPlaneSettings = .default) {
        self.netID = netID
        self.priority = priority
        self.fromRules = fromRules
        self.settings = settings
    }

    init(plane: HorizontalPlane) {
        netID = plane.netID
        priority = plane.priority
        fromRules = plane.fromRules
        settings = plane.settings
    }
}

extension HorizontalPlane {
    /// A plane for `polygon` on the draft's net, with its settings.
    init(polygon: HorizontalPolygon, draft: HorizontalPlaneEditorDraft) {
        self.init(
            id: UUID().uuidString.lowercased(),
            netID: draft.netID,
            polygonID: polygon.id,
            layer: polygon.layer,
            priority: draft.priority,
            fillStyle: "solid",
            minWidth: 0,
            keepOrphans: false,
            fragments: [],
            fallbackPolygon: polygon
        )
        apply(draft)
    }

    /// Takes the editor's values, keeping the mirrored legacy fields
    /// (`fillStyle`, `minWidth`, `keepOrphans`) in step with `settings`.
    mutating func apply(_ draft: HorizontalPlaneEditorDraft) {
        netID = draft.netID
        priority = draft.priority
        fromRules = draft.fromRules
        settings = draft.settings
        fillStyle = draft.settings.fillStyle == .hatch ? "hatch" : "solid"
        minWidth = Double(draft.settings.minWidth)
        keepOrphans = draft.settings.keepOrphans
    }
}
