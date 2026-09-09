#if os(macOS)
import AppKit
import Foundation

/// Saving an open document on demand.
///
/// An edit through the live channel becomes one undoable step in the app and
/// nothing more; the file only changes when the document is written. SwiftUI's
/// `DocumentGroup` has no API for that, but it is `NSDocumentController`
/// underneath, so the document can be found by its URL and written through its
/// own pipeline — which keeps the read-only guard, the write notification the
/// pool editors listen for, and the edited flag all behaving as they do when
/// the user presses Save.
///
/// Targeting the document by URL rather than sending the Save action matters:
/// an automation client is not the key window, and often the app is not even
/// frontmost.
enum HorizontalDocumentSaving {
    /// The open document for `url`, if the document system has one.
    @MainActor
    static func document(for url: URL) -> NSDocument? {
        let wanted = url.resolvingSymlinksInPath().standardizedFileURL
        return NSDocumentController.shared.documents.first { document in
            document.fileURL?.resolvingSymlinksInPath().standardizedFileURL == wanted
        }
    }

    @MainActor
    static func isEdited(url: URL) -> Bool {
        document(for: url)?.isDocumentEdited ?? false
    }

    /// Writes the document at `url` to its file. A document with nothing to
    /// write is left alone rather than rewritten, so a save does not churn
    /// timestamps a build might be watching.
    @MainActor
    static func save(url: URL) throws {
        guard let document = document(for: url) else {
            throw HorizontalDispatchError.notFound(
                "The document system has no open document for \(url.path), so there is nothing to save."
            )
        }
        guard document.isDocumentEdited else {
            return
        }
        guard let fileURL = document.fileURL, let type = document.fileType else {
            throw HorizontalDispatchError.failed("The document has never been written, so it has no file to save to.")
        }
        // `writeSafely` is the synchronous primitive the Save command runs;
        // the asynchronous forms would have to complete on this same main
        // thread, which is the one the request is being answered on.
        try document.writeSafely(to: fileURL, ofType: type, for: .saveOperation)
        document.updateChangeCount(.changeCleared)
        // The document compares this against the file before its next write;
        // leaving it stale makes the app think another program edited it.
        if let modified = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date {
            document.fileModificationDate = modified
        }
    }
}
#endif
