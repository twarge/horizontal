#if os(macOS)
import AppKit
import SwiftUI

/// One window per pool, keyed by the pool directory, the way Horizon's pool
/// manager opens a pool.json: "Open in Pool" from any library browser lands
/// here, as does the Pools menu's "Open in Separate Window".
@MainActor
final class HorizontalPoolWindowManager {
    static let shared = HorizontalPoolWindowManager()

    private var controllers = [String: HorizontalPoolWindowController]()

    private init() {}

    func open(
        poolURL: URL,
        reveal: HorizontalPoolRevealRequest? = nil,
        appearanceSettings: HorizontalAppearanceSettings
    ) {
        let standardized = poolURL.standardizedFileURL
        let controller = controllers[standardized.path] ?? HorizontalPoolWindowController(poolURL: standardized)
        controllers[standardized.path] = controller
        controller.show(reveal: reveal, appearanceSettings: appearanceSettings)
    }
}

/// The reveal request lives in a model the window's content observes, so a
/// later "Open in Pool" for another item re-selects without rebuilding the
/// browser (and losing its scan, sort and search).
@MainActor
final class HorizontalPoolWindowModel: ObservableObject {
    @Published var revealRequest: HorizontalPoolRevealRequest?
}

@MainActor
final class HorizontalPoolWindowController: NSObject, NSWindowDelegate {
    let poolURL: URL

    private let model = HorizontalPoolWindowModel()
    private var window: NSWindow?

    init(poolURL: URL) {
        self.poolURL = poolURL
    }

    func show(reveal: HorizontalPoolRevealRequest?, appearanceSettings: HorizontalAppearanceSettings) {
        if window == nil {
            let content = HorizontalPoolWindowContent(poolURL: poolURL, model: model)
                .environmentObject(appearanceSettings)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = HorizontalPoolRegistryStore.poolInfo(at: poolURL).name
            window.subtitle = poolURL.path
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1040, height: 720))
            window.minSize = NSSize(width: 760, height: 480)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            window.setFrameAutosaveName("Horizontal Pool \(poolURL.path)")
            self.window = window
        }
        if let reveal {
            model.revealRequest = reveal
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct HorizontalPoolWindowContent: View {
    var poolURL: URL
    @ObservedObject var model: HorizontalPoolWindowModel
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings

    var body: some View {
        HorizontalPoolBrowserView(root: .pool(poolURL), revealRequest: model.revealRequest)
            .preferredColorScheme(appearanceSettings.preferredColorScheme)
            .frame(minWidth: 760, minHeight: 480)
    }
}
#endif
