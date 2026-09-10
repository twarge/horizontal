#if os(macOS)
import AppIntents

/// The phrases that work without the user setting anything up.
///
/// Every phrase has to carry the app's name — that is the framework's rule,
/// not a choice — so they read "in Horizontal" rather than as bare commands.
/// A phrase with a parameter in it is only matched against values the app has
/// published, which is why `HorizontalDesignObjectQuery.suggestedEntities`
/// returns the open document's components and nets and why the workspace
/// re-publishes them when the document changes.
struct HorizontalAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: HighlightDesignObjectIntent(),
            phrases: [
                "Highlight \(\.$object) in \(.applicationName)",
                "Show me \(\.$object) in \(.applicationName)",
            ],
            shortTitle: "Highlight",
            systemImageName: "highlighter"
        )
        AppShortcut(
            intent: ClearHighlightIntent(),
            phrases: [
                "Clear the highlight in \(.applicationName)",
                "Clear \(.applicationName)'s highlight",
            ],
            shortTitle: "Clear Highlight",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: ShowPanesIntent(),
            phrases: [
                "Show the \(\.$choice) in \(.applicationName)",
                "Open the \(\.$choice) in \(.applicationName)",
            ],
            shortTitle: "Show Panes",
            systemImageName: "rectangle.split.2x1"
        )
        AppShortcut(
            intent: ZoomToDesignObjectIntent(),
            phrases: [
                "Zoom to \(\.$object) in \(.applicationName)",
                "Find \(\.$object) in \(.applicationName)",
            ],
            shortTitle: "Zoom To",
            systemImageName: "magnifyingglass"
        )
    }
}
#endif
