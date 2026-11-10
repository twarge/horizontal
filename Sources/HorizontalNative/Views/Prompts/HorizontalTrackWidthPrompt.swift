#if os(macOS)
import AppKit

/// Modal numeric prompt for the track-drawing `w` (track width) key — the
/// Horizontal analog of `ask_datum` width entry. Works in
/// millimeters (the unit users think in) and returns the value in the board's
/// internal nanometers, or nil if cancelled or invalid.
enum HorizontalTrackWidthPrompt {
    private static let nmPerMM = 1_000_000.0

    @MainActor
    static func run(
        title: String = "Track Width",
        message: String = "Enter the track width in millimeters.",
        currentWidthNM: Double,
        allowsZero: Bool = false
    ) -> Double? {
        runNumber(
            title: title,
            message: message,
            current: max(currentWidthNM, 0) / nmPerMM,
            placeholder: "0.2",
            allowsZero: allowsZero
        ).map { ($0 * nmPerMM).rounded() }
    }

    /// A plain number, as typed: the place-decal tool's scale (Horizon's
    /// enter-datum scale window). Nil if cancelled, or for anything but a
    /// positive number (or zero, with `allowsZero`).
    @MainActor
    static func runNumber(
        title: String,
        message: String,
        current: Double,
        placeholder: String,
        allowsZero: Bool = false
    ) -> Double? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.alignment = .right
        field.stringValue = String(format: "%g", current)
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = Double(text), value.isFinite, value > 0 || (allowsZero && value == 0) else {
            return nil
        }
        return value
    }
}
#endif
