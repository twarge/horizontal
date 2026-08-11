#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
final class HorizontalNativeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard !Self.hasVisibleDocumentWindow else {
                return
            }

            self.openProject()
        }
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openProject()
        return true
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = HorizontalProjectDocument.readableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Open a project (.hprj or .horizontal)"
        panel.prompt = "Open"
        panel.treatsFilePackagesAsDirectories = false

        // Non-modal: runModal() here blocks the main thread, which stalls the
        // odoc Apple Event for documents opened at launch (Finder/`open`),
        // making those opens time out (-1712) behind the panel.
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error {
                    Self.present(error: error)
                }
            }
        }
    }

    private static var hasVisibleDocumentWindow: Bool {
        NSApplication.shared.windows.contains { window in
            window.isVisible && !window.isMiniaturized && window.canBecomeMain
        }
    }

    private static func present(error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
#endif
