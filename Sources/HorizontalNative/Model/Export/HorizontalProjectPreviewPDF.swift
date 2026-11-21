#if canImport(AppKit)
import AppKit
import PDFKit
import SwiftUI

/// A project as one PDF, for Quick Look: the board in 3D from the top and
/// from the bottom, a page each, then the schematic's pages as the schematic
/// PDF prints them, then the board drawing. A project with no board starts
/// at its schematic; one with no schematic is the board's three pages.
@MainActor
enum HorizontalProjectPreviewPDF {
    /// The longer side of a 3D page, in pixels and in points: A4's long
    /// side, at a little under 300 dpi.
    static let viewPixels = 2400.0
    static let viewPoints = 842.0
    /// How much wider and taller than the board a 3D page is, for the parts
    /// that overhang its edge.
    static let viewMargin = 1.12

    static func document(
        for project: HorizontalProject,
        appearance: HorizontalAppearanceSettings = HorizontalAppearanceSettings()
    ) async throws -> PDFDocument {
        let hasSchematic = !HorizontalExportBackend.schematicPages(of: project).isEmpty
        let drawings = Task.detached(priority: .userInitiated) {
            (
                schematic: hasSchematic ? Result { try drawing { try HorizontalExportBackend.writeSchematicPreviewPDF(project: project, to: $0) } } : nil,
                board: project.board == nil ? nil : Result { try drawing { try HorizontalExportBackend.writeBoardPreviewPDF(project: project, to: $0) } }
            )
        }
        var views = [PDFPage]()
        if let board = project.board {
            do {
                views = try await boardViews(of: board, appearance: appearance)
            } catch {
                // The drawings are still worth showing.
                NSLog("Preview: the 3D views could not be rendered: %@", String(describing: error))
            }
        }
        let drawn = await drawings.value

        let document = PDFDocument()
        var failure: Error?
        for page in views {
            document.insert(page, at: document.pageCount)
        }
        for result in [drawn.schematic, drawn.board] {
            switch result {
            case .success(let data):
                guard let pages = PDFDocument(data: data) else {
                    continue
                }
                for index in 0..<pages.pageCount {
                    if let page = pages.page(at: index)?.copy() as? PDFPage {
                        document.insert(page, at: document.pageCount)
                    }
                }
            case .failure(let error):
                failure = failure ?? error
            case nil:
                break
            }
        }
        guard document.pageCount > 0 else {
            throw failure ?? NothingToShow()
        }
        return document
    }

    /// The PDF `write` makes at a temporary file, read back.
    private nonisolated static func drawing(_ write: (URL) throws -> Void) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPreview-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(url)
        return try Data(contentsOf: url)
    }

    /// The board from above and from below, each a page its shape, in the
    /// colours the 3D view has.
    private static func boardViews(of board: HorizontalBoard, appearance: HorizontalAppearanceSettings) async throws -> [PDFPage] {
        let clipping = appearance.silkscreenClipping
        let description = await Task.detached(priority: .userInitiated) {
            BoardSceneFactory.describeScene(for: board, silkscreenClipping: clipping)
        }.value
        let scene = BoardSceneEntities(description: description)
        scene.applyDisplayOptions(
            BoardDisplayOptions(),
            copperColor: appearance.boardSceneCopper,
            materialColors: appearance.boardSceneMaterialColors,
            layerColors: appearance.boardSceneLayerColors
        )

        let dimensions = horizonSceneBoardDimensions(for: board)
        let longest = max(dimensions.width, dimensions.depth)
        let pixels = CGSize(
            width: (dimensions.width / longest * viewPixels).rounded(),
            height: (dimensions.depth / longest * viewPixels).rounded()
        )
        let points = CGSize(width: pixels.width * viewPoints / viewPixels, height: pixels.height * viewPoints / viewPixels)
        let background = BoardSceneColor(NSColor(appearance.boardSceneBackground))

        var pages = [PDFPage]()
        for preset in [HorizontalBoard3DViewPreset.top, .bottom] {
            // Both look along the board's normal with its far edge up the
            // page, so the bottom is the board turned over left to right, as
            // a hand turns it; the app's own Bottom view turns it end over
            // end. The camera's scale is half the view's height.
            var camera = horizonSceneCameraState(for: preset, board: board)
            if let matrix = camera.matrix {
                camera = HorizontalSceneCameraState(
                    matrix: BoardSceneCameraMath.lookAt(
                        position: BoardSceneCameraMath.position(of: matrix),
                        target: .zero,
                        up: SIMD3(0, 0, -1)
                    ),
                    orthographicScale: dimensions.depth * viewMargin / 2
                )
            }
            let image = try await BoardSceneOffscreenRenderer.render(
                scene,
                camera: camera,
                projection: .orthogonal,
                size: pixels,
                background: background
            )
            if let page = PDFPage(image: NSImage(cgImage: image, size: points)) {
                pages.append(page)
            }
        }
        return pages
    }

    private struct NothingToShow: LocalizedError {
        var errorDescription: String? { "This project has no schematic and no board." }
    }
}
#endif
