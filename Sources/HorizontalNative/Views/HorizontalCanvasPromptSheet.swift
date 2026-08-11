import SwiftUI

/// A request to present a modal text / number / option-picker input over the canvas.
///
/// macOS draw tools use synchronous `NSAlert`s; SwiftUI has no synchronous modal, so on
/// iOS the canvas publishes one of these (`presentCanvasPrompt`) and the body presents
/// `HorizontalCanvasPromptSheet` via `.horizonCanvasPrompt(_:)`. The completion fires
/// exactly once with the entered value, or `nil` if cancelled / swipe-dismissed (so a
/// mid-draw tool can revert).
struct HorizontalCanvasPromptRequest: Identifiable {
    enum Content {
        case text(seed: String, completion: (String?) -> Void)
        case number(seed: Double?, unit: String, completion: (Double?) -> Void)
        case optionPicker(options: [HorizontalSelectionPropertyOption], selected: String?, completion: (String?) -> Void)
    }

    let id = UUID()
    var title: String
    var confirmTitle: String = "Done"
    var content: Content
}

struct HorizontalCanvasPromptSheet: View {
    let request: HorizontalCanvasPromptRequest

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var numberText = ""
    @State private var selectedOptionID = ""
    @State private var didComplete = false

    var body: some View {
        NavigationStack {
            Form {
                switch request.content {
                case .text:
                    TextField("Text", text: $text)
                        #if os(iOS)
                        .textInputAutocapitalization(.sentences)
                        #endif
                case .number(_, let unit, _):
                    HStack {
                        TextField("Value", text: $numberText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        Text(unit).foregroundStyle(.secondary)
                    }
                case .optionPicker(let options, _, _):
                    Picker("Selection", selection: $selectedOptionID) {
                        ForEach(options) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle(request.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { deliver(confirmed: false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.confirmTitle) { deliver(confirmed: true) }
                        .disabled(!canConfirm)
                }
            }
        }
        .onAppear(perform: seedInitialValue)
        .onDisappear {
            // A swipe-to-dismiss (no button) counts as cancel.
            deliver(confirmed: false)
        }
    }

    private func seedInitialValue() {
        switch request.content {
        case .text(let seed, _):
            text = seed
        case .number(let seed, _, _):
            numberText = seed.map { Self.format($0) } ?? ""
        case .optionPicker(let options, let selected, _):
            selectedOptionID = selected ?? options.first?.id ?? ""
        }
    }

    private var canConfirm: Bool {
        switch request.content {
        case .text:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number:
            return Self.parse(numberText) != nil
        case .optionPicker:
            return !selectedOptionID.isEmpty
        }
    }

    /// Fires the case's completion once (value on confirm, nil on cancel) and dismisses.
    private func deliver(confirmed: Bool) {
        guard !didComplete else { return }
        didComplete = true
        switch request.content {
        case .text(_, let completion):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(confirmed && !trimmed.isEmpty ? trimmed : nil)
        case .number(_, _, let completion):
            completion(confirmed ? Self.parse(numberText) : nil)
        case .optionPicker(_, _, let completion):
            completion(confirmed && !selectedOptionID.isEmpty ? selectedOptionID : nil)
        }
        dismiss()
    }

    private static func parse(_ string: String) -> Double? {
        Double(string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

extension View {
    /// Presents a `HorizontalCanvasPromptSheet` when `request` is non-nil. Cross-platform,
    /// but only ever triggered on iOS (macOS tools keep their synchronous `NSAlert`s).
    func horizonCanvasPrompt(_ request: Binding<HorizontalCanvasPromptRequest?>) -> some View {
        sheet(item: request) { HorizontalCanvasPromptSheet(request: $0) }
    }
}
