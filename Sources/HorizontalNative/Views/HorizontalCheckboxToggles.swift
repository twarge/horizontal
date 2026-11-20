import SwiftUI

extension View {
    /// The toggles inside as checkboxes on macOS, which is how a Mac app's
    /// settings are drawn; a grouped form, left to itself, would draw them
    /// as switches. In a grouped form the checkbox leads its row, and a
    /// second Text in a toggle's label goes under the title as help text.
    /// iPadOS keeps its switches, so this does nothing there. It goes on
    /// the form or container: a toggle style reaches every toggle inside.
    @ViewBuilder
    func checkboxTogglesOnMac() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}
