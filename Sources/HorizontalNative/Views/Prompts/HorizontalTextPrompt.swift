#if os(macOS)
import AppKit

/// Modal text-entry prompt for the "Add Text" board action. Returns the entered
/// string, or nil if cancelled or empty.
enum HorizontalTextPrompt {
    @MainActor
    static func run(seed: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = "Add Text"
        alert.informativeText = "Enter the text to place on the board."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = seed
        field.placeholderString = "Text"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
#endif
