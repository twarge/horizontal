#if canImport(AppKit)
import AppKit

/// The dialogs behind the schematic's bus and net-tie tools.
///
/// Each step is one question — which bus, which member, which net — because
/// that is the shape the objects have: a bus grows a member at a time, and a
/// tie joins one pair of nets. Horizon asks the same things in a manage
/// dialog; asking them in order needs no new window, and every answer is a
/// step the user can back out of by cancelling.
enum HorizontalSchematicObjectPrompt {
    struct Option {
        var id: String
        var name: String
    }

    enum Choice: Equatable {
        /// One of the options, by id.
        case existing(String)
        /// A new one, by the name the user typed.
        case new(String)
    }

    /// Picks one of `options`, or — when `newTitle` is given — names a new
    /// one. With no options and no escape there is nothing to ask, so the
    /// prompt reports that instead of showing an empty popup.
    @MainActor
    static func choose(
        title: String,
        message: String,
        options: [Option],
        confirmTitle: String = "Choose",
        newTitle: String? = nil,
        newMessage: String = "",
        seed: String = ""
    ) -> Choice? {
        guard !options.isEmpty else {
            guard let newTitle else {
                report(title: title, message: message)
                return nil
            }
            return name(title: newTitle, message: newMessage, seed: seed).map(Choice.new)
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        if let newTitle {
            alert.addButton(withTitle: "\(newTitle)…")
        }
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for option in options {
            popup.addItem(withTitle: option.name)
            popup.lastItem?.representedObject = option.id
        }
        alert.accessoryView = popup

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return (popup.selectedItem?.representedObject as? String).map(Choice.existing)
        case .alertSecondButtonReturn:
            guard let newTitle else { return nil }
            return name(title: newTitle, message: newMessage, seed: seed).map(Choice.new)
        default:
            return nil
        }
    }

    /// Asks for a name. Empty is a cancel: a bus or a member with no name is
    /// one nothing can refer to.
    @MainActor
    static func name(title: String, message: String, seed: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = seed
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return entered.isEmpty ? nil : entered
    }

    /// Says why a tool cannot start — no nets to tie, no bus to rip from.
    @MainActor
    static func report(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
