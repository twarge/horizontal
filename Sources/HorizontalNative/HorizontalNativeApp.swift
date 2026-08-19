import Foundation
import SwiftUI

#if DEBUG && os(macOS)
import Darwin
#endif

@main
struct HorizontalNativeApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(HorizontalNativeAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var appearanceSettings = HorizontalAppearanceSettings()

    init() {
        HorizontalDebugConsoleFilter.installIfNeeded()
    }

    var body: some Scene {
        #if os(macOS)
        DocumentGroup(newDocument: HorizontalProjectDocument.newProject()) { configuration in
            ProjectDocumentView(configuration: configuration, document: configuration.$document)
                .environmentObject(appearanceSettings)
                .preferredColorScheme(appearanceSettings.preferredColorScheme)
        }
        .commands {
            HorizontalAboutCommands()
            HorizontalViewCommands()
        }

        Settings {
            HorizontalSettingsView()
                .environmentObject(appearanceSettings)
                .preferredColorScheme(appearanceSettings.preferredColorScheme)
        }
        #else
        DocumentGroup(newDocument: HorizontalProjectDocument.newProject()) { configuration in
            HorizontalIPadProjectView(
                document: configuration.$document,
                fileURL: configuration.fileURL
            )
            .environmentObject(appearanceSettings)
            .preferredColorScheme(appearanceSettings.preferredColorScheme)
        }

        // The opening screen: title, Create Document, and the document browser
        // for existing projects, replacing the bare Files browser as the launch
        // experience.
        DocumentGroupLaunchScene("Horizontal") {
            NewDocumentButton("Create Document")
        } background: {
            HorizontalLaunchBackground()
        }
        #endif
    }
}

#if os(iOS)
/// Backdrop for the launch scene: the dark copper-on-substrate palette of the
/// board canvas, so the opening screen reads as this app rather than a stock
/// document browser.
private struct HorizontalLaunchBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.24, blue: 0.20),
                Color(red: 0.03, green: 0.08, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
#endif

#if DEBUG && os(macOS)
private final class HorizontalDebugConsoleFilter: @unchecked Sendable {
    static let shared = HorizontalDebugConsoleFilter()

    private static let suppressedLines: Set<String> = [
        "BoardCanvasView: _hoveredObject changed.",
        "BoardCanvasView: @self, _viewport changed.",
        "BoardCanvasView: @self changed."
    ]

    private var installed = false
    private var descriptors = [FilteredDescriptor]()

    static func installIfNeeded() {
        guard ProcessInfo.processInfo.environment["HORIZONTAL_SHOW_SWIFTUI_CHANGE_LOGS"] != "1" else {
            return
        }
        shared.install()
    }

    private func install() {
        guard !installed else {
            return
        }
        installed = true

        if let stdoutDescriptor = FilteredDescriptor(fileDescriptor: STDOUT_FILENO) {
            descriptors.append(stdoutDescriptor)
        }
        if let stderrDescriptor = FilteredDescriptor(fileDescriptor: STDERR_FILENO) {
            descriptors.append(stderrDescriptor)
        }
    }

    private final class FilteredDescriptor: @unchecked Sendable {
        private let readDescriptor: Int32
        private let originalDescriptor: Int32
        private let source: DispatchSourceRead
        private var pending = Data()

        init?(fileDescriptor: Int32) {
            var pipeDescriptors = [Int32](repeating: 0, count: 2)
            guard Darwin.pipe(&pipeDescriptors) == 0 else {
                return nil
            }

            let duplicateDescriptor = Darwin.dup(fileDescriptor)
            guard duplicateDescriptor >= 0 else {
                Darwin.close(pipeDescriptors[0])
                Darwin.close(pipeDescriptors[1])
                return nil
            }

            guard Darwin.dup2(pipeDescriptors[1], fileDescriptor) >= 0 else {
                Darwin.close(pipeDescriptors[0])
                Darwin.close(pipeDescriptors[1])
                Darwin.close(duplicateDescriptor)
                return nil
            }

            Darwin.close(pipeDescriptors[1])
            _ = Darwin.fcntl(pipeDescriptors[0], F_SETFL, O_NONBLOCK)

            readDescriptor = pipeDescriptors[0]
            originalDescriptor = duplicateDescriptor
            source = DispatchSource.makeReadSource(
                fileDescriptor: pipeDescriptors[0],
                queue: DispatchQueue(label: "com.twarge.horizontal.debug-console-filter")
            )
            source.setEventHandler { [weak self] in
                self?.drain()
            }
            source.resume()
        }

        deinit {
            source.cancel()
            Darwin.close(readDescriptor)
            Darwin.close(originalDescriptor)
        }

        private func drain() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(readDescriptor, &buffer, buffer.count)
                guard count > 0 else {
                    break
                }
                pending.append(buffer, count: count)
                flushCompleteLines()
            }
        }

        private func flushCompleteLines() {
            while let newlineIndex = pending.firstIndex(of: 10) {
                let lineEnd = pending.index(after: newlineIndex)
                let line = pending[..<lineEnd]
                pending.removeSubrange(..<lineEnd)
                writeUnlessSuppressed(Data(line))
            }

            if pending.count > 16_384 {
                writeUnlessSuppressed(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }

        private func writeUnlessSuppressed(_ data: Data) {
            if let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .newlines),
               HorizontalDebugConsoleFilter.suppressedLines.contains(line) {
                return
            }

            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                _ = Darwin.write(originalDescriptor, baseAddress, bytes.count)
            }
        }
    }
}
#else
private enum HorizontalDebugConsoleFilter {
    static func installIfNeeded() {}
}
#endif
