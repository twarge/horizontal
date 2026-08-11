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

    var archive: HorizontalProjectArchive

    init(rawProjectData: Data = Data()) {
        archive = HorizontalProjectArchive(regularFileData: rawProjectData)
    }

    init(configuration: ReadConfiguration) throws {
        archive = try BoardLoadTimer.measureStandalone("FileDocument read configuration") {
            try HorizontalProjectArchive(fileWrapper: configuration.file)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard !HorizontalOperationDefaults.readOnlyOperation() else {
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
        guard configuration.contentType.conforms(to: .package), !replacingRegularFile else {
            return try archive.projectFileWrapper()
        }
        return try archive.fileWrapper()
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
