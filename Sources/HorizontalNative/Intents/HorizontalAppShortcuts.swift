import AppIntents

/// The phrases that work without the user setting anything up.
///
/// Every phrase has to carry the app's name — that is the framework's rule,
/// not a choice — so they read "in Horizontal" rather than as bare commands.
/// The one parameter is an enum, so the phrases match without the app having
/// published anything; a phrase with an entity in it would match only values
/// the app had pushed to Siri beforehand, which is why the design's own names
/// are heard by the app instead — and why Siri's other job here is to turn
/// that listening on.
struct HorizontalAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowPanesIntent(),
            phrases: [
                "Show the \(\.$choice) in \(.applicationName)",
                "Show me the \(\.$choice) in \(.applicationName)",
                "Open the \(\.$choice) in \(.applicationName)",
                "Switch to the \(\.$choice) in \(.applicationName)",
            ],
            shortTitle: "Show Panes",
            systemImageName: "rectangle.split.2x1"
        )
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: [
                "Start listening in \(.applicationName)",
                "Listen in \(.applicationName)",
                "Start voice control in \(.applicationName)",
                "Turn on voice control in \(.applicationName)",
            ],
            shortTitle: "Start Listening",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: StopListeningIntent(),
            phrases: [
                "Stop listening in \(.applicationName)",
                "Stop voice control in \(.applicationName)",
                "Turn off voice control in \(.applicationName)",
            ],
            shortTitle: "Stop Listening",
            systemImageName: "mic.slash"
        )
    }
}
