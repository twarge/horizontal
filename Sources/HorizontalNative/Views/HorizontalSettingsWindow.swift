#if os(macOS)
import AppKit
import SwiftUI

/// The app menu's Settings… opens the settings form in a window of the app's
/// own. SwiftUI's Settings scene keeps its window a fixed size: it takes
/// `.resizable` out of the style mask on every layout pass, whatever the
/// scene's resizability says, so the form, much of it colour tables, could
/// never be made taller. The window here grows and shrinks in height only:
/// the form is laid out for its one width.
struct HorizontalSettingsCommands: Commands {
    var appearanceSettings: HorizontalAppearanceSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                HorizontalSettingsWindowController.shared.show(appearanceSettings: appearanceSettings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// One Settings window, kept when closed and brought forward when asked for
/// again, at the size and place it was left.
@MainActor
final class HorizontalSettingsWindowController {
    static let shared = HorizontalSettingsWindowController()

    private static let defaultContentSize = NSSize(width: HorizontalSettingsView.minimumSize.width, height: 640)
    private static let frameAutosaveName = "Horizontal Settings"

    private var window: NSWindow?

    private init() {}

    func show(appearanceSettings: HorizontalAppearanceSettings) {
        if window == nil {
            let content = HorizontalSettingsWindowContent()
                .environmentObject(appearanceSettings)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "Horizontal Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = HorizontalSettingsView.minimumSize
            window.contentMaxSize = NSSize(width: HorizontalSettingsView.minimumSize.width, height: .greatestFiniteMagnitude)
            window.setContentSize(Self.defaultContentSize)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.collectionBehavior.insert(.fullScreenNone)
            if window.setFrameUsingName(Self.frameAutosaveName) {
                // A frame saved while the window could still be made wider
                // keeps its height and takes the form's width.
                let height = window.contentRect(forFrameRect: window.frame).height
                window.setContentSize(NSSize(width: Self.defaultContentSize.width, height: height))
            } else {
                window.center()
            }
            window.setFrameAutosaveName(Self.frameAutosaveName)
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The theme recolours the form as it does every window, Settings' own
/// picker included.
private struct HorizontalSettingsWindowContent: View {
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    var body: some View {
        HorizontalSettingsView()
            .preferredColorScheme(appearanceSettings.preferredColorScheme)
    }
}
#endif
