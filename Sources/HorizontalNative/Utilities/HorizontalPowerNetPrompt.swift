#if canImport(AppKit)
import AppKit

/// The dialogs behind "Place Power Symbol": pick one of the block's power
/// nets, or make one — Horizon's manage-power-nets step reduced to a name
/// and a symbol style.
enum HorizontalPowerNetPrompt {
    struct Option {
        var id: String
        var name: String
    }

    enum Choice: Equatable {
        case existing(String)
        case new(name: String, style: String)
    }

    /// Horizon's `power_symbol_style` values and their names.
    static let styles: [(id: String, title: String)] = [
        ("gnd", "Ground"),
        ("earth", "Earth"),
        ("dot", "Dot"),
        ("antenna", "Antenna"),
    ]

    @MainActor
    static func run(nets: [Option]) -> Choice? {
        guard !nets.isEmpty else {
            return runNew()
        }
        let alert = NSAlert()
        alert.messageText = "Place Power Symbol"
        alert.informativeText = "Choose the power net the symbols connect to."
        alert.addButton(withTitle: "Place")
        alert.addButton(withTitle: "New Power Net…")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for net in nets {
            popup.addItem(withTitle: net.name)
            popup.lastItem?.representedObject = net.id
        }
        alert.accessoryView = popup

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return (popup.selectedItem?.representedObject as? String).map(Choice.existing)
        case .alertSecondButtonReturn:
            return runNew()
        default:
            return nil
        }
    }

    @MainActor
    static func runNew(defaultName: String = "GND") -> Choice? {
        let alert = NSAlert()
        alert.messageText = "New Power Net"
        alert.informativeText = "Name the net and choose how its symbol is drawn."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 32, width: 240, height: 24))
        field.stringValue = defaultName
        field.placeholderString = "GND"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for style in styles {
            popup.addItem(withTitle: style.title)
            popup.lastItem?.representedObject = style.id
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 58))
        container.addSubview(field)
        container.addSubview(popup)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let style = popup.selectedItem?.representedObject as? String else {
            return nil
        }
        return .new(name: name, style: style)
    }
}
#endif
