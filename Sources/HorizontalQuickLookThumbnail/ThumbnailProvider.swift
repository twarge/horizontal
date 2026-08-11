import AppKit
#if canImport(HorizontalNative)
import HorizontalNative
#endif
import os
import QuickLookThumbnailing

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    private let logger = Logger(subsystem: "com.twarge.horizontal", category: "QuickLookThumbnail")

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let startedAt = Date()
        let fileURL = request.fileURL
        let maximumSize = request.maximumSize
        logger.notice("Preparing thumbnail for \(fileURL.path, privacy: .public), size \(maximumSize.width, privacy: .public)x\(maximumSize.height, privacy: .public)")
        nonisolated(unsafe) let completion = handler
        Task.detached(priority: .userInitiated) { [logger] in
            do {
                let image: NSImage
                do {
                    image = try HorizontalBoardThumbnailRenderer.image(
                        forProjectAt: fileURL,
                        fitting: maximumSize
                    )
                } catch {
                    logger.error("Board thumbnail failed for \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    image = try HorizontalSchematicPreviewRenderer.image(
                        forProjectAt: fileURL,
                        fitting: maximumSize
                    )
                }
                let reply = QLThumbnailReply(contextSize: image.size, currentContextDrawing: {
                    let rect = NSRect(origin: .zero, size: image.size)
                    NSColor.windowBackgroundColor.setFill()
                    rect.fill()
                    image.draw(in: rect)
                    return true
                })
                reply.extensionBadge = "horizontal"
                logger.notice("Thumbnail ready for \(fileURL.path, privacy: .public) in \(Date().timeIntervalSince(startedAt), privacy: .public)s")
                completion(reply, nil)
            } catch {
                logger.error("Thumbnail failed for \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                completion(nil, error)
            }
        }
    }
}
