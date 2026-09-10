import Foundation

/// Telling the system which names its spoken phrases can carry.
///
/// The workspace knows when the answer changed; the App Intents code that acts
/// on it is app-only, and the QuickLook extensions compile the workspace but
/// not the intents. So the workspace calls this and the app fills it in — the
/// same shape as every other app-only file being excluded from the extensions
/// and nothing shared referring to it by name.
@MainActor
enum HorizontalIntentParameterPublishing {
    /// Installed by the app at launch. Nil in the extensions, which vend no
    /// intents and have nothing to publish.
    static var publish: (() -> Void)?

    static func parametersDidChange() {
        publish?()
    }
}
