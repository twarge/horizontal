#if os(macOS)
import AppKit

/// Modal net chooser for "Draw Plane" — the Horizontal analog of the
/// edit-plane dialog net button. The reference requires a plane to be bound to a net
/// (its OK button stays disabled until one is picked); cancelling returns nil so
/// the caller reverts the draw. Options are `(id, name)`, presented by name.
enum HorizontalPlaneNetPrompt {
    @MainActor
    static func run(nets: [HorizontalSelectionPropertyOption]) -> String? {
        guard !nets.isEmpty else {
            return nil
        }

        let alert = NSAlert()
        alert.messageText = "Plane Net"
        alert.informativeText = "Choose the net this copper plane pours on."
        alert.addButton(withTitle: "Create Plane")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 25), pullsDown: false)
        for net in nets {
            popup.addItem(withTitle: net.title)
            popup.lastItem?.representedObject = net.id
        }
        alert.accessoryView = popup
        alert.window.initialFirstResponder = popup

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return popup.selectedItem?.representedObject as? String ?? nets.first?.id
    }
}
#endif
