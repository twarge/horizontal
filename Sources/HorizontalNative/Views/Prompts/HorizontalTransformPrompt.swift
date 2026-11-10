#if os(macOS)
import AppKit

/// Modal numeric prompts for the precise-transform actions ("Move exactly",
/// "Rotate arbitrary"), the Horizontal analog of `ask_datum` entry.
/// Values are entered in the units users think in (mm, degrees) and returned in
/// board-internal nanometers / degrees, or nil when cancelled or invalid.
enum HorizontalTransformPrompt {
    private static let nmPerMM = 1_000_000.0

    /// Relative move offset, returned as a nanometer delta.
    @MainActor
    static func runMoveExactly() -> HorizontalPoint? {
        guard let values = runFields(
            title: "Move Exactly",
            message: "Enter the offset in millimeters.",
            confirm: "Move",
            fields: [("ΔX (mm):", "0"), ("ΔY (mm):", "0")]
        ) else {
            return nil
        }
        guard let dx = parse(values[0]), let dy = parse(values[1]) else {
            return nil
        }
        return HorizontalPoint(x: (dx * nmPerMM).rounded(), y: (dy * nmPerMM).rounded())
    }

    /// Rotation angle in degrees (counter-clockwise positive).
    @MainActor
    static func runRotateDegrees() -> Double? {
        guard let values = runFields(
            title: "Rotate",
            message: "Enter the rotation angle in degrees.",
            confirm: "Rotate",
            fields: [("Angle (°):", "0")]
        ) else {
            return nil
        }
        guard let degrees = parse(values[0]), degrees != 0 else {
            return nil
        }
        return degrees
    }

    private static func parse(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else {
            return nil
        }
        return value
    }

    /// Shows a modal NSAlert with one right-aligned text field per `fields` row,
    /// returning the entered strings (in order) or nil if cancelled.
    @MainActor
    private static func runFields(
        title: String,
        message: String,
        confirm: String,
        fields: [(label: String, seed: String)]
    ) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")

        let rowHeight = 24.0
        let spacing = 8.0
        let width = 230.0
        let labelWidth = 74.0
        let fieldWidth = width - labelWidth - spacing
        let height = rowHeight * Double(fields.count) + spacing * Double(max(fields.count - 1, 0))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        var textFields = [NSTextField]()
        for (index, spec) in fields.enumerated() {
            let y = height - rowHeight - Double(index) * (rowHeight + spacing)
            let label = NSTextField(labelWithString: spec.label)
            label.frame = NSRect(x: 0, y: y, width: labelWidth, height: rowHeight)
            label.alignment = .right
            container.addSubview(label)

            let field = NSTextField(frame: NSRect(x: labelWidth + spacing, y: y, width: fieldWidth, height: rowHeight))
            field.alignment = .right
            field.stringValue = spec.seed
            container.addSubview(field)
            textFields.append(field)
        }
        // Tab cycles between fields.
        for index in textFields.indices {
            textFields[index].nextKeyView = textFields[(index + 1) % textFields.count]
        }
        alert.accessoryView = container
        alert.window.initialFirstResponder = textFields.first

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return textFields.map(\.stringValue)
    }
}
#endif
