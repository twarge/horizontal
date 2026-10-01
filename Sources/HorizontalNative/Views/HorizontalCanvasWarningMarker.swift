import SwiftUI

struct HorizontalCanvasWarningMarker: View {
    var warning: HorizontalCanvasWarning
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.yellow, .black)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(warning.messages.joined(separator: "\n"))
        .accessibilityLabel(warning.messages.joined(separator: ". "))
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(warning.messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                }
            }
            .font(.callout)
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }
}
