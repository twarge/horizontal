#if os(macOS)
import AppIntents
import Foundation

/// Which panes to show. `both` is here because it is what someone actually
/// asks for when their hands are full — the alternative is two requests.
enum HorizontalPaneChoice: String, AppEnum {
    case schematic
    case board
    case both

    var panes: Set<HorizontalPane> {
        switch self {
        case .schematic: [.schematic]
        case .board: [.board]
        case .both: [.schematic, .board]
        }
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Panes" }
    static var caseDisplayRepresentations: [HorizontalPaneChoice: DisplayRepresentation] {
        [.schematic: "Schematic", .board: "Board", .both: "Both"]
    }
}

/// Which canvas to frame something in. Left unset, the app picks — the board
/// when the component is placed there, the schematic otherwise — which is the
/// same rule `zoom_to` follows for an agent.
enum HorizontalZoomPane: String, AppEnum {
    case automatic
    case schematic
    case board

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Pane" }
    static var caseDisplayRepresentations: [HorizontalZoomPane: DisplayRepresentation] {
        [.automatic: "Whichever fits", .schematic: "Schematic", .board: "Board"]
    }
}

struct HighlightDesignObjectIntent: AppIntent {
    static var title: LocalizedStringResource { "Highlight" }
    static var description: IntentDescription {
        IntentDescription("Highlights a component or a net in Horizontal's canvases.")
    }
    /// The point is to look at the app, so bring it forward.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Component or Net")
    var object: HorizontalDesignObjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Highlight \(\.$object)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try HorizontalIntentTarget.current()
        let key = object.kind == .component ? "components" : "nets"
        _ = try HorizontalIntentTarget.call("highlight", handle: target.handle, params: [key: [object.name]])
        return .result(dialog: "Highlighted \(object.name).")
    }
}

struct ClearHighlightIntent: AppIntent {
    static var title: LocalizedStringResource { "Clear Highlight" }
    static var description: IntentDescription {
        IntentDescription("Clears whatever Horizontal is highlighting.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try HorizontalIntentTarget.current()
        _ = try HorizontalIntentTarget.call(
            "highlight", handle: target.handle, params: ["components": [String](), "nets": [String]()]
        )
        return .result(dialog: "Highlight cleared.")
    }
}

struct ShowPanesIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Panes" }
    static var description: IntentDescription {
        IntentDescription("Shows the schematic, the board, or both in Horizontal's window.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Show")
    var choice: HorizontalPaneChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Show the \(\.$choice)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try HorizontalIntentTarget.current()
        _ = try HorizontalIntentTarget.call(
            "show_panes", handle: target.handle, params: ["panes": choice.panes.map(\.rawValue)]
        )
        return .result(dialog: choice == .both ? "Showing both." : "Showing the \(choice.rawValue).")
    }
}

struct ZoomToDesignObjectIntent: AppIntent {
    static var title: LocalizedStringResource { "Zoom To" }
    static var description: IntentDescription {
        IntentDescription("Frames a component or a net in Horizontal's board or schematic.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Component or Net")
    var object: HorizontalDesignObjectEntity

    @Parameter(title: "In", default: .automatic)
    var pane: HorizontalZoomPane

    static var parameterSummary: some ParameterSummary {
        Summary("Zoom to \(\.$object)") {
            \.$pane
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try HorizontalIntentTarget.current()
        var params: JSONDictionary = object.kind == .component ? ["refdes": object.name] : ["net": object.name]
        if pane != .automatic {
            params["pane"] = pane.rawValue
        }
        let result = try HorizontalIntentTarget.call("zoom_to", handle: target.handle, params: params)
        // Framing something reads better with the pane named, and zoom_to
        // reports which one it chose when the caller did not.
        let framed = result.string("pane").map { " in the \($0)" } ?? ""
        return .result(dialog: "Zoomed to \(object.name)\(framed).")
    }
}
#endif
