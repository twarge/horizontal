import SwiftUI

/// A determinate circular progress ring.
///
/// Drawn rather than delegating to `ProgressView(value:)` with the circular
/// style, which ignores the value and spins on iOS — this app ships to both
/// platforms and the indicator has to mean the same thing on each.
struct CanvasProgressRing: View {
    var progress: Double
    var diameter: CGFloat = 46
    /// Off at rail-button size, where the digits would be unreadable anyway.
    var showsPercentage = true

    private var clamped: Double { min(max(progress, 0), 1) }
    private var lineWidth: CGFloat { max(diameter / 11, 2) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Start at twelve o'clock; `trim` begins at three.
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: clamped)

            if showsPercentage {
                // Monospaced so the ring does not jitter as digits change width.
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The rail button's spinner for a pour too small to report a fraction.
/// `ProgressView` at this size renders inconsistently inside a button label, so
/// the ring is reused with a fixed arc that simply rotates.
struct CanvasIndeterminateRing: View {
    var diameter: CGFloat

    @State private var isSpinning = false

    private var lineWidth: CGFloat { max(diameter / 11, 2) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isSpinning)
        }
        .frame(width: diameter, height: diameter)
        .onAppear { isSpinning = true }
    }
}
