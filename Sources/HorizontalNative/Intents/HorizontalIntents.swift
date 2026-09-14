import AppIntents
import Foundation

/// Which panes to show: each canvas alone, and every way of combining them,
/// because "show me the schematic and the board" is one request, not two.
enum HorizontalPaneChoice: String, AppEnum {
    case schematic
    case board
    case threeD
    case schematicAndBoard
    case schematicAndThreeD
    case boardAndThreeD
    case everything

    var panes: Set<HorizontalPane> {
        switch self {
        case .schematic: [.schematic]
        case .board: [.board]
        case .threeD: [.threeD]
        case .schematicAndBoard: [.schematic, .board]
        case .schematicAndThreeD: [.schematic, .threeD]
        case .boardAndThreeD: [.board, .threeD]
        case .everything: [.schematic, .board, .threeD]
        }
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Panes" }
    static var caseDisplayRepresentations: [HorizontalPaneChoice: DisplayRepresentation] {
        [
            .schematic: "Schematic",
            .board: DisplayRepresentation(title: "Board", synonyms: ["PCB", "Layout"]),
            .threeD: DisplayRepresentation(title: "3D view", synonyms: ["3D", "3D board", "Model"]),
            .schematicAndBoard: DisplayRepresentation(title: "Schematic and board", synonyms: ["Board and schematic", "Both"]),
            .schematicAndThreeD: DisplayRepresentation(title: "Schematic and 3D", synonyms: ["3D and schematic"]),
            .boardAndThreeD: DisplayRepresentation(title: "Board and 3D", synonyms: ["3D and board"]),
            .everything: DisplayRepresentation(title: "Schematic, board and 3D", synonyms: ["Everything", "All three", "All panes"]),
        ]
    }
}

/// The one intent Siri keeps: showing panes. It is general — every document
/// has a schematic and a board — and its parameter is an enum, which needs
/// nothing published. Everything that names a part of the design is spoken
/// to the app itself instead (`HorizontalVoiceControl`), where the design's
/// names are known before they are heard.
struct ShowPanesIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Panes" }
    static var description: IntentDescription {
        IntentDescription("Shows the schematic, the board, the 3D view, or any combination in Horizontal's window.")
    }
    /// The point is to look at the app, so bring it forward.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Show")
    var choice: HorizontalPaneChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Show the \(\.$choice)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Opening the app may be what is bringing its documents back; give
        // the one in front a moment to register before deciding none is open.
        let target = try await HorizontalCommandTarget.current(waitingUpTo: .seconds(3))
        try HorizontalCommandTarget.showPanes(choice.panes, in: target)
        return .result(dialog: "Showing \(HorizontalVoiceCommandRunner.list(choice.panes)).")
    }
}

/// Siri's way into the app's own listening: "start listening in Horizontal"
/// opens the app and turns the microphone on for the document in front, so
/// the design's names are heard by the app — which knows them — rather than
/// by Siri, which does not.
struct StartListeningIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Listening" }
    static var description: IntentDescription {
        IntentDescription("Turns on Horizontal's voice control for the open project, so you can say \"highlight C12\" or \"show the top layer\" to the app.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await HorizontalCommandTarget.current(waitingUpTo: .seconds(3))
        guard let control = HorizontalVoiceControl.control(forHandle: target.handle) else {
            throw HorizontalCommandError.refused("Voice control is not available for \(target.document.title).")
        }
        control.start()
        return .result(dialog: "Listening.")
    }
}

struct StopListeningIntent: AppIntent {
    static var title: LocalizedStringResource { "Stop Listening" }
    static var description: IntentDescription {
        IntentDescription("Turns off Horizontal's voice control.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try HorizontalCommandTarget.current()
        HorizontalVoiceControl.control(forHandle: target.handle)?.stop()
        return .result(dialog: "Stopped listening.")
    }
}
