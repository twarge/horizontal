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

    /// Records that the document at `url` has changes its file does not.
    ///
    /// An edit arriving through the live channel goes onto the undo stack of
    /// whichever undo manager the view can reach, and when the app is not
    /// frontmost — which is the automation case — that is a fallback manager
    /// the document system knows nothing about. Without this the document
    /// never learns it changed: Save stays disabled, closing the window offers
    /// no prompt, and an automation client's edit can be thrown away without
    /// anyone being asked.
    @MainActor
    static func markEdited(url: URL) {
        document(for: url)?.updateChangeCount(.changeDone)
    }

    /// The undo manager Undo actually routes to for this document.
    ///
    /// A view reads `\.undoManager` from the environment, which is nil unless
    /// the view is in a focused document scene — so an edit arriving while the
    /// app is in the background lands on whatever fallback the view holds, and
    /// the user cannot undo it. The document's own manager is the one the Undo
    /// command uses, whether or not anyone is looking at the window.
    @MainActor
    static func undoManager(url: URL) -> UndoManager? {
        document(for: url)?.undoManager
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
