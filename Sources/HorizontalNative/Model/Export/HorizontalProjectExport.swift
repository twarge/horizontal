import Foundation
#if canImport(HorizontalProjectIO)
import HorizontalProjectIO
#endif

/// File ▸ Export…: a copy of the project as a Horizontal package or as a
/// Horizon project folder, the folder Horizon opens a `.hprj` from. The window
/// stays on its own file; the copy holds the document as it is now, unsaved
/// edits included. Either way the copy's `.hprj` is named after what it is
/// exported as.
enum HorizontalProjectExport {
    enum Format: String, CaseIterable, Identifiable {
        case package
        case horizonFolder

        var id: String { rawValue }

        var title: String {
            switch self {
            case .package: "Horizontal Package (.horizontal)"
            case .horizonFolder: "Horizon Project Folder (.hprj)"
            }
        }
    }

    enum ExportError: LocalizedError, Equatable {
        case ontoItself(String)
        case readOnlyOverwrite(String)

        var errorDescription: String? {
            switch self {
            case .ontoItself(let name):
                "“\(name)” is where this project is. Save it instead, or export it somewhere else."
            case .readOnlyOverwrite(let name):
                "“\(name)” already exists, and read-only is on. Export to a new name, or turn read-only off in Settings."
            }
        }
    }

    /// The format offered first: the one the project is not in already.
    static func defaultFormat(for project: HorizontalProject) -> Format {
        isPackage(project.url) ? .horizonFolder : .package
    }

    /// The name offered: the project's own, without `.horizontal` or `.hprj`.
    static func suggestedName(for project: HorizontalProject) -> String {
        let name = project.url.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "horizontal" || ext == "hprj" ? (name as NSString).deletingPathExtension : name
    }

    /// Where an export chosen at `url` goes: a package's name ends in
    /// `.horizontal`, a folder's doesn't.
    static func destination(for url: URL, format: Format) -> URL {
        switch format {
        case .package:
            return isPackage(url) ? url : url.appendingPathExtension("horizontal")
        case .horizonFolder:
            return isPackage(url) ? url.deletingPathExtension() : url
        }
    }

    /// Every file of the project: the document's own archive when it holds
    /// them, as a package's and an opened `.hprj`'s do, or the files gathered
    /// from disk for a `.hprj` opened read-only, which holds its `.hprj` alone.
    static func archive(from document: HorizontalProjectArchive, project: HorizontalProject) throws -> HorizontalProjectArchive {
        if case .directory = document.root {
            return document
        }
        return try HorizontalProjectArchive.completeProject(from: project.projectFileURL)
    }

    /// Writes the copy of `archive` chosen at `url` and returns where it went.
    /// A package there already is replaced, as Save As replaces one. A folder
    /// there already keeps everything but the project's files, which are
    /// replaced: a Horizon project folder often holds fabrication outputs,
    /// notes or a repository beside the project. Neither may be the project's
    /// own place, and read-only writes only where nothing is yet.
    @discardableResult
    static func export(
        _ archive: HorizontalProjectArchive,
        of project: HorizontalProject,
        as format: Format,
        to url: URL,
        isReadOnly: Bool
    ) throws -> URL {
        let destination = destination(for: url, format: format)
        let place = canonical(destination)
        if place == canonical(project.url) || place == canonical(project.baseURL) {
            throw ExportError.ontoItself(destination.lastPathComponent)
        }
        if isReadOnly, FileManager.default.fileExists(atPath: destination.path) {
            throw ExportError.readOnlyOverwrite(destination.lastPathComponent)
        }
        var named = archive.renamingProjectFile(toMatchPackageNamed: destination.lastPathComponent)
        // Where the files were read from says nothing about the copy.
        named.manifest = nil
        switch format {
        case .package:
            try named.write(to: destination)
        case .horizonFolder:
            try named.writeContents(into: destination)
        }
        return destination
    }

    private static func isPackage(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("horizontal") == .orderedSame
    }

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// The save panel for File ▸ Export…, with a Format popup under it, run as a
/// sheet on the project's window.
@MainActor
final class HorizontalProjectExportPanel: NSObject {
    private let panel = NSSavePanel()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var format: HorizontalProjectExport.Format
    /// The panel running now, kept until it closes.
    private static var running: HorizontalProjectExportPanel?

    private init(format: HorizontalProjectExport.Format, name: String) {
        self.format = format
        super.init()
        panel.title = "Export Project"
        panel.prompt = "Export"
        panel.message = "A Horizon project folder holds the .hprj and the files it names. Exporting into a folder that exists replaces those files and leaves the rest."
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = name
        popup.addItems(withTitles: HorizontalProjectExport.Format.allCases.map(\.title))
        popup.selectItem(at: HorizontalProjectExport.Format.allCases.firstIndex(of: format) ?? 0)
        popup.target = self
        popup.action = #selector(formatChanged(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = row
        apply(format)
    }

    /// Asks where and as what, then writes the copy `archive` gives.
    static func run(
        project: HorizontalProject,
        isReadOnly: Bool,
        window: NSWindow?,
        archive: @escaping () throws -> HorizontalProjectArchive
    ) {
        guard running == nil else { return }
        let controller = HorizontalProjectExportPanel(
            format: HorizontalProjectExport.defaultFormat(for: project),
            name: HorizontalProjectExport.suggestedName(for: project)
        )
        running = controller
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            running = nil
            guard response == .OK, let url = controller.panel.url else { return }
            do {
                try HorizontalProjectExport.export(try archive(), of: project, as: controller.format, to: url, isReadOnly: isReadOnly)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "The project couldn’t be exported."
                alert.informativeText = error.localizedDescription
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }
        if let window {
            controller.panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(controller.panel.runModal())
        }
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        format = HorizontalProjectExport.Format.allCases[max(sender.indexOfSelectedItem, 0)]
        apply(format)
    }

    /// A package's name takes `.horizontal`; a folder's goes without.
    private func apply(_ format: HorizontalProjectExport.Format) {
        var name = panel.nameFieldStringValue
        if (name as NSString).pathExtension.caseInsensitiveCompare("horizontal") == .orderedSame {
            name = (name as NSString).deletingPathExtension
        }
        switch format {
        case .package:
            panel.allowedContentTypes = [.horizontalProject]
            panel.nameFieldStringValue = name + ".horizontal"
        case .horizonFolder:
            panel.allowedContentTypes = []
            panel.nameFieldStringValue = name
        }
    }
}
#endif
