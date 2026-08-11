#if os(macOS)
import AppKit

/// Modal numeric prompt for the track-drawing `w` (track width) key — the
/// Horizontal analog of `ask_datum` width entry. Works in
/// millimeters (the unit users think in) and returns the value in the board's
/// internal nanometers, or nil if cancelled or invalid.
enum HorizontalTrackWidthPrompt {
    private static let nmPerMM = 1_000_000.0

    @MainActor
    static func run(currentWidthNM: Double) -> Double? {
        let alert = NSAlert()
        alert.messageText = "Track Width"
        alert.informativeText = "Enter the track width in millimeters."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.alignment = .right
        let seed = max(currentWidthNM, 0) / nmPerMM
        field.stringValue = String(format: "%g", seed)
        field.placeholderString = "0.2"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let mm = Double(text), mm.isFinite, mm > 0 else {
            return nil
        }
        return (mm * nmPerMM).rounded()
    }
}
#endif
