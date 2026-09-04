import Foundation
#if canImport(HorizontalProjectIO)
import HorizontalProjectIO
#endif
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let horizontalProject = UTType(exportedAs: "com.twarge.horizontal-project", conformingTo: .package)
    static let hprjProject = UTType(exportedAs: "com.twarge.hprj-project", conformingTo: .json)
    /// Imported, not exported: `.hprj` is another program's format and this is
    /// the identifier it registers. Without it the app is not offered for files
    /// that program tagged, which is most of them.
    static let legacyHorizonProject = UTType(importedAs: "org.horizon-eda.horizon-project", conformingTo: .json)
}

struct HorizontalProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.horizontalProject, .hprjProject, .legacyHorizonProject, .json] }
    static var writableContentTypes: [UTType] { [.horizontalProject, .hprjProject, .json] }

    /// Posted from `fileWrapper` for every save, autosave included, with the
    /// archive being written as the object. `WriteConfiguration` carries no
    /// URL, so a pool item editor recognises its own save by matching the
    /// archive against the bytes it last handed the document.
    static let didWriteNotification = Notification.Name("HorizontalProjectDocumentDidWrite")

    var archive: HorizontalProjectArchive

    init(rawProjectData: Data = Data()) {
        archive = HorizontalProjectArchive(regularFileData: rawProjectData)
    }

    /// The document `DocumentGroup` hands out for File > New (macOS) and Create
    /// Document (iPadOS): a complete empty project rather than an empty file,
    /// which nothing could load. Package-shaped, so a brand-new document saves
    /// as a `.horizontal` bundle without needing an in-place `.hprj` manifest.
    static func newProject() -> HorizontalProjectDocument {
        var document = HorizontalProjectDocument()
        document.archive = .newProject()
        return document
    }

    init(configuration: ReadConfiguration) throws {
        archive = try BoardLoadTimer.measureStandalone("FileDocument read configuration") {
            try HorizontalProjectArchive(fileWrapper: configuration.file)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Read-only operation protects the user's EXISTING projects from this
        // app's still-maturing editors. Writing a file that does not exist yet —
        // Create Document on iPadOS, File > New's first save, Save As to a new
        // location — can't touch any of them, so it stays allowed even when the
        // build is locked; otherwise the opening screen's Create Document could
        // only ever fail in a shipping build.
        let creatingNewFile = configuration.existingFile == nil
        guard creatingNewFile || !HorizontalOperationDefaults.readOnlyOperation() else {
            throw HorizontalProjectDocumentError.readOnlyOperation
        }

        // ONLY the .horizontal package may be written as a directory.
        //
        // A Horizon .hprj is plain JSON with its blocks/schematic/board/pool as
        // siblings on disk. Opening one calls `completeProject(from:)`, which
        // gathers all of that into a directory-rooted archive (so it can ALSO be
        // saved as a .horizontal package) — and returning that directory for a
        // .hprj URL is what replaced the user's project file with a folder of
        // the same name. `projectFileWrapper()` instead writes the siblings back
        // where they came from and returns just the project JSON.
        //
        // The `existingFile` check is deliberate belt-and-braces: whatever the
        // declared content type says, never hand a directory to a URL that is
        // currently a regular file.
        let replacingRegularFile = configuration.existingFile?.isRegularFile ?? false
        // iOS document creation can hand this write an unresolved dynamic type
        // for the `.horizontal` extension instead of the declared package type.
        // A brand-new document's archive — directory-rooted with no manifest
        // mapping files back to disk — has no single-file representation at
        // all, so for a dynamic type the archive's own shape decides. Only for
        // a dynamic type: a RESOLVED non-package type is the user explicitly
        // saving as `.hprj`, which must keep refusing (missingManifest's
        // save-as-package message) rather than write a folder named `.hprj`.
        var isNewPackageArchive = false
        if case .directory = archive.root, archive.manifest == nil {
            isNewPackageArchive = true
        }
        let writingPackage = configuration.contentType.conforms(to: .package)
            || (configuration.contentType.isDynamic && isNewPackageArchive)
        guard writingPackage, !replacingRegularFile else {
            let wrapper = try archive.projectFileWrapper()
            NotificationCenter.default.post(name: Self.didWriteNotification, object: archive)
            return wrapper
        }
        let wrapper = try archive.fileWrapper()
        NotificationCenter.default.post(name: Self.didWriteNotification, object: archive)
        return wrapper
    }
}

enum HorizontalProjectDocumentError: LocalizedError {
    case readOnlyOperation

    var errorDescription: String? {
        switch self {
        case .readOnlyOperation:
            // Release builds have no toggle to point at, so don't send the user
            // looking for one that isn't there.
            HorizontalOperationDefaults.isReadOnlyOperationForced
                ? "This build of Horizontal cannot modify project files."
                : "Read-only operation is enabled. Disable it in Settings before saving project files."
        }
    }
}
