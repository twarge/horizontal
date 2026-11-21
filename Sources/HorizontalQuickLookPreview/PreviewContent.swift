import Foundation

/// A project read for a preview.
struct PreviewProject {
    var project: HorizontalProject

    static func load(at url: URL) throws -> PreviewProject {
        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var result: Result<HorizontalProject, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try HorizontalProject.load(from: coordinatedURL) }
        }
        if let result {
            return PreviewProject(project: try result.get())
        }
        if let coordinationError {
            throw coordinationError
        }
        throw PreviewError("Quick Look could not coordinate access to \(url.lastPathComponent).")
    }
}

struct PreviewError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
