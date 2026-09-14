import SwiftUI

/// The microphone in the toolbar: press to listen, press again to stop.
struct HorizontalVoiceControlButton: View {
    @ObservedObject var control: HorizontalVoiceControl

    private var title: String { control.isListening ? "Stop Listening" : "Listen for a Command" }

    var body: some View {
        Button {
            control.toggle()
        } label: {
            Label(title, systemImage: control.isListening ? "mic.fill" : "mic")
                .symbolEffect(.pulse, isActive: control.isListening)
        }
        .tint(control.isListening ? .red : nil)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// What is being heard and what came of it, floating over the canvas while
/// listening and for a moment after. Never in the way: it takes no clicks.
struct HorizontalVoiceTranscriptOverlay: View {
    @ObservedObject var control: HorizontalVoiceControl

    var body: some View {
        Group {
            if control.isListening || control.message != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if control.isListening {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, isActive: control.status == nil)
                            Text(control.status ?? (control.transcript.isEmpty ? "Listening…" : control.transcript))
                                .lineLimit(2)
                        }
                    }
                    if let message = control.message {
                        Text(message)
                            .lineLimit(3)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 520, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.2), value: control.isListening)
        .animation(.snappy(duration: 0.2), value: control.message)
    }
}
