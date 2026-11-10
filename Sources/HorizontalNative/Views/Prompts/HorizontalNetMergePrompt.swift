#if canImport(AppKit)
import AppKit

/// Horizon's "Merge nets" dialog (`AskNetMergeDialog`): an edit joined two
/// nets that both have names, so one name has to go. Cancel leaves the edit
/// undone.
enum HorizontalNetMergePrompt {
    enum Choice: Equatable {
        /// The first net named goes into the second, whose name stays.
        case mergeNetIntoOther
        /// The second goes into the first.
        case mergeOtherIntoNet
    }

    @MainActor
    static func run(netName: String, intoName: String) -> Choice? {
        let alert = NSAlert()
        alert.messageText = "Merge Nets"
        alert.informativeText = "This connects “\(netName)” and “\(intoName)”, which both have names. "
            + "The nets become one, under one of the names."
        alert.addButton(withTitle: "Merge “\(netName)” into “\(intoName)”")
        alert.addButton(withTitle: "Merge “\(intoName)” into “\(netName)”")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .mergeNetIntoOther
        case .alertSecondButtonReturn:
            return .mergeOtherIntoNet
        default:
            return nil
        }
    }
}
#endif
