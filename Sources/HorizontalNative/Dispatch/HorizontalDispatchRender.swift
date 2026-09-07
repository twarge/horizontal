import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PNG renders of sheets and the board, made by running the app's own PDF
/// exporters into a temporary directory and rasterizing the page.
enum HorizontalDispatchRender {
    struct Image {
        var png: Data
        var width: Int
        var height: Int
    }

    static func renderSheet(
        project: HorizontalProject,
        sheetIndex: Int?,
        sheetName: String?,
        sheetID: String? = nil,
        region: HorizontalRect? = nil,
        dpi: Double,
        maxPixels: Int
    ) throws -> (Image, HorizontalSchematicSheet) {
        let sheets = HorizontalDesignIndex.schematics(of: project).flatMap { $0.schematic.sheets }
        guard !sheets.isEmpty else {
            throw HorizontalDispatchError.failed("The project has no schematic sheets.")
        }
        let position: Int
        if let sheetID {
            guard let found = sheets.firstIndex(where: { $0.id.caseInsensitiveCompare(sheetID) == .orderedSame }) else {
                throw HorizontalDispatchError.notFound("No sheet with id \(sheetID).")
            }
            position = found
        } else if let sheetIndex {
            guard let found = sheets.firstIndex(where: { $0.index == sheetIndex }) else {
                throw HorizontalDispatchError.notFound("No sheet with index \(sheetIndex).")
            }
            position = found
        } else if let sheetName {
            guard let found = sheets.firstIndex(where: { $0.name.caseInsensitiveCompare(sheetName) == .orderedSame }) else {
                throw HorizontalDispatchError.notFound("No sheet named \(sheetName).")
            }
            position = found
        } else {
            position = 0
        }
        let sheet = sheets[position]
        let pdfURL = try exportPDF(project: project, section: .schematicPDF) { _ in }
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }
        // The exporter fits the sheet's frame (or its content) onto a page with
        // no margin; the same mapping locates a region on that page.
        let crop = region.map { pageRect(for: $0, bounds: sheetPageBounds(sheet), margin: 0) }
        let image = try rasterize(pdfURL: pdfURL, page: position + 1, dpi: dpi, maxPixels: maxPixels, crop: crop)
        return (image, sheet)
    }

    static func renderBoard(
        project: HorizontalProject,
        layerNames: [String]?,
        mirrored: Bool,
        region: HorizontalRect? = nil,
        dpi: Double,
        maxPixels: Int
    ) throws -> Image {
        guard let board = project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        let pdfURL = try exportPDF(project: project, section: .boardDrawing) { settings in
            settings.boardDrawing.mirrored = mirrored
            if let layerNames, !layerNames.isEmpty {
                let wanted = Set(layerNames.map { $0.lowercased() })
                for index in settings.boardDrawing.layers.indices {
                    let layer = settings.boardDrawing.layers[index]
                    settings.boardDrawing.layers[index].enabled = wanted.contains(layer.name.lowercased()) || wanted.contains(String(layer.layer))
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }
        // The exporter pads the board's physical bounds by 8% and fits them
        // onto the page inside a 36-point margin; mirror this to crop.
        let crop = region.map { pageRect(for: $0, bounds: boardPageBounds(board), margin: 36) }
        return try rasterize(pdfURL: pdfURL, page: 1, dpi: dpi, maxPixels: maxPixels, crop: crop)
    }

    // MARK: - Page mapping (mirrors the PDF exporter)

    static func boardPageBounds(_ board: HorizontalBoard) -> HorizontalRect {
        (board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds).padded(0.08)
    }

    static func sheetPageBounds(_ sheet: HorizontalSchematicSheet) -> HorizontalRect {
        let framePoints = sheet.frameLines.flatMap { [$0.from, $0.to] }
            + sheet.framePolygons.flatMap { $0.renderVertices(arcPrecision: 32) }
        let frameBounds = HorizontalRect(points: framePoints)
        if !frameBounds.isEmpty, frameBounds.width > 0, frameBounds.height > 0 {
            return frameBounds
        }
        return sheet.bounds.padded(0.02)
    }

    /// Where a world rectangle lands on a page whose content `bounds` were
    /// fitted inside `margin`, as the exporter's world transform does. The
    /// page size is read from the PDF at raster time; this returns the rect
    /// as a function of it.
    static func pageRect(for region: HorizontalRect, bounds: HorizontalRect, margin: CGFloat) -> (CGSize) -> CGRect {
        { pageSize in
            let content = bounds.isEmpty ? HorizontalRect(center: .zero, size: 100_000_000) : bounds
            let availableWidth = max(pageSize.width - margin * 2, 1)
            let availableHeight = max(pageSize.height - margin * 2, 1)
            let scale = min(availableWidth / CGFloat(max(content.width, 1)), availableHeight / CGFloat(max(content.height, 1)))
            let origin = CGPoint(
                x: (pageSize.width - CGFloat(max(content.width, 1)) * scale) / 2,
                y: (pageSize.height - CGFloat(max(content.height, 1)) * scale) / 2
            )
            return CGRect(
                x: origin.x + CGFloat(region.minX - content.minX) * scale,
                y: origin.y + CGFloat(region.minY - content.minY) * scale,
                width: max(CGFloat(region.width) * scale, 1),
                height: max(CGFloat(region.height) * scale, 1)
            )
        }
    }

    /// The layers the board drawing exporter offers, with its defaults.
    static func boardDrawingLayers(project: HorizontalProject) -> [JSONDictionary] {
        let settings = HorizontalExportSettings(project: project)
        return settings.boardDrawing.layers.map { ["layer": $0.layer, "name": $0.name, "enabled_by_default": $0.enabled] }
    }

    private static func exportPDF(
        project: HorizontalProject,
        section: HorizontalExportSection,
        configure: (inout HorizontalExportSettings) -> Void
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var settings = HorizontalExportSettings(project: project)
        settings.targetDirectory = directory.path
        configure(&settings)
        let status = HorizontalExportBackend.export(sections: [section], settings: settings, project: project)
        guard status.kind != .error else {
            try? FileManager.default.removeItem(at: directory)
            throw HorizontalDispatchError.failed(status.message)
        }
        let filename = section == .schematicPDF ? settings.schematicPDF.filename : settings.boardDrawing.filename
        return directory.appendingPathComponent(filename)
    }

    private static func rasterize(
        pdfURL: URL,
        page pageNumber: Int,
        dpi: Double,
        maxPixels: Int,
        crop: ((CGSize) -> CGRect)? = nil
    ) throws -> Image {
        guard let document = CGPDFDocument(pdfURL as CFURL) else {
            throw HorizontalDispatchError.failed("Could not open the rendered PDF.")
        }
        guard pageNumber >= 1, pageNumber <= document.numberOfPages, let page = document.page(at: pageNumber) else {
            throw HorizontalDispatchError.notFound("The PDF has no page \(pageNumber).")
        }
        let mediaBox = page.getBoxRect(.mediaBox)
        let box = crop.map { $0(mediaBox.size) } ?? mediaBox
        var scale = max(dpi, 1) / 72
        let longest = max(box.width, box.height) * scale
        if longest > Double(max(maxPixels, 16)) {
            scale *= Double(max(maxPixels, 16)) / longest
        }
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw HorizontalDispatchError.failed("Could not create a bitmap context.")
        }
        if let white = CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1]) {
            context.setFillColor(white)
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else {
            throw HorizontalDispatchError.failed("Could not rasterize the page.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw HorizontalDispatchError.failed("Could not create the PNG encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HorizontalDispatchError.failed("Could not encode the PNG.")
        }
        return Image(png: data as Data, width: width, height: height)
    }
}
