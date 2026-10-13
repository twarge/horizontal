import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension View {
    /// Escape in a pane's search field leaves the field, keeping its text, so
    /// the keyboard goes back to the canvas with the keyboard-focus badge. A
    /// click on the canvas does the same (`TrackpadCanvasMonitor`).
    func leavesFieldOnEscape() -> some View {
        onKeyPress(.escape) {
            #if os(macOS)
            NSApp.keyWindow?.makeFirstResponder(nil)
            #else
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
            return .handled
        }
    }
}
