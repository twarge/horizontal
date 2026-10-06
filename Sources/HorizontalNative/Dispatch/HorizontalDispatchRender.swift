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
        blockID: String? = nil,
        region: HorizontalRect? = nil,
        dpi: Double,
        maxPixels: Int
    ) throws -> (Image, HorizontalSchematicSheet) {
        let all = HorizontalDesignIndex.schematics(of: project)
        let scoped = all.flatMap { block in block.schematic.sheets.map { (blockID: block.block.uuid, sheet: $0) } }
        let sheets = scoped.map(\.sheet)
        guard !sheets.isEmpty else {
            throw HorizontalDispatchError.failed("The project has no schematic sheets.")
        }
        let matches = scoped.indices.filter { index in
            let value = scoped[index]
            return (blockID.map { value.blockID.caseInsensitiveCompare($0) == .orderedSame } ?? true)
                && (sheetID.map { value.sheet.id.caseInsensitiveCompare($0) == .orderedSame } ?? true)
                && (sheetIndex.map { value.sheet.index == $0 } ?? true)
                && (sheetName.map { value.sheet.name.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
        guard let position = matches.first else { throw HorizontalDispatchError.notFound("No sheet matches the selector.") }
        if matches.count > 1 && (sheetID != nil || sheetIndex != nil || sheetName != nil || blockID != nil) {
            throw HorizontalDispatchError.ambiguous("Sheet selector is ambiguous.", candidates: matches.map { "\(scoped[$0].blockID)/\(scoped[$0].sheet.id)" })
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
        layerIDs: [Int]? = nil,
        mirrored: Bool,
        region: HorizontalRect? = nil,
        airwires: [HorizontalSegment]? = nil,
        dpi: Double,
        maxPixels: Int
    ) throws -> Image {
        guard let board = project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        // The exporter draws no airwires, and the PDF it writes is for
        // fabrication drawings, which shouldn't gain them; they go on the
        // raster instead, on the page the exporter laid out.
        let mapping = { (pageSize: CGSize) in PageMapping(bounds: boardPageBounds(board), margin: 36, pageSize: pageSize) }
        let overlay = airwires.map { segments in
            { (context: CGContext, pageSize: CGSize, pixelsPerPoint: CGFloat) in
                drawAirwires(segments, in: context, mapping: mapping(pageSize), pixelsPerPoint: pixelsPerPoint)
            }
        }
        let selected = try resolveBoardLayers(project: project, names: layerNames, ids: layerIDs)
        let pdfURL = try exportPDF(project: project, section: .boardDrawing) { settings in
            settings.boardDrawing.mirrored = mirrored
            if let selected {
                for index in settings.boardDrawing.layers.indices {
                    settings.boardDrawing.layers[index].enabled = selected.contains(settings.boardDrawing.layers[index].layer)
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }
        // The exporter pads the board's physical bounds by 8% and fits them
        // onto the page inside a 36-point margin; mirror this to crop.
        let crop = region.map { pageRect(for: $0, bounds: boardPageBounds(board), margin: 36) }
        return try rasterize(pdfURL: pdfURL, page: 1, dpi: dpi, maxPixels: maxPixels, crop: crop, overlay: overlay)
    }

    /// The colour airwires are drawn in on a render: on the exporter's white
    /// page the canvas's cyan barely shows, so a deeper blue, dashed as the
    /// canvas dashes them.
    static let airwireColor: [CGFloat] = [0, 0.4, 0.95, 1]

    /// Airwires as dashed lines about 1.5 pixels wide, whatever the
    /// resolution, so they read the same at any dpi.
    private static func drawAirwires(_ airwires: [HorizontalSegment], in context: CGContext,
                                     mapping: PageMapping, pixelsPerPoint: CGFloat) {
        guard !airwires.isEmpty else {
            return
        }
        let pixel = 1 / max(pixelsPerPoint, 0.01)
        context.saveGState()
        context.setStrokeColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: airwireColor)
            ?? CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1.5 * pixel)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [6 * pixel, 4 * pixel])
        for airwire in airwires {
            context.move(to: mapping.point(airwire.from))
            context.addLine(to: mapping.point(airwire.to))
        }
        context.strokePath()
        context.restoreGState()
    }

    /// The exporter's per-project list is also the selector contract.
    static func resolveBoardLayers(project: HorizontalProject, names: [String]?, ids: [Int]?) throws -> Set<Int>? {
        guard names == nil || ids == nil else {
            throw HorizontalDispatchError.invalidParams("Use layers or layer_ids, not both.")
        }
        let valid = boardDrawingLayers(project: project)
        var selected = Set<Int>()
        var unknown = [String]()
        for name in names ?? [] {
            let matches = valid.filter {
                ($0.string("name")?.caseInsensitiveCompare(name) == .orderedSame)
                    || $0.int("layer").map(String.init) == name
                    || $0.int("layer").map { HorizontalBoardLayers.name(for: $0).caseInsensitiveCompare(name) == .orderedSame } == true
            }
            if matches.count == 1, let id = matches[0].int("layer") { selected.insert(id) }
            else { unknown.append(name) }
        }
        let validIDs = Set(valid.compactMap { $0.int("layer") })
        for id in ids ?? [] {
            if validIDs.contains(id) { selected.insert(id) } else { unknown.append(String(id)) }
        }
        guard unknown.isEmpty else {
            throw HorizontalDispatchError(code: .invalidParams,
                message: "Unknown or ambiguous board layers: \(unknown.joined(separator: ", ")). Use board_info.drawing_layers.",
                details: ["requested": unknown, "valid_layers": valid])
        }
        return selected.isEmpty ? nil : selected
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

    /// The exporter's world transform: content `bounds` fitted inside
    /// `margin` on a page of `pageSize`, centred. The page size is read from
    /// the PDF at raster time.
    struct PageMapping {
        var content: HorizontalRect
        var scale: CGFloat
        var origin: CGPoint

        init(bounds: HorizontalRect, margin: CGFloat, pageSize: CGSize) {
            content = bounds.isEmpty ? HorizontalRect(center: .zero, size: 100_000_000) : bounds
            let availableWidth = max(pageSize.width - margin * 2, 1)
            let availableHeight = max(pageSize.height - margin * 2, 1)
            scale = min(availableWidth / CGFloat(max(content.width, 1)), availableHeight / CGFloat(max(content.height, 1)))
            origin = CGPoint(
                x: (pageSize.width - CGFloat(max(content.width, 1)) * scale) / 2,
                y: (pageSize.height - CGFloat(max(content.height, 1)) * scale) / 2
            )
        }

        func point(_ point: HorizontalPoint) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(point.x - content.minX) * scale,
                    y: origin.y + CGFloat(point.y - content.minY) * scale)
        }
    }

    /// Where a world rectangle lands on that page, as a function of the page
    /// size.
    static func pageRect(for region: HorizontalRect, bounds: HorizontalRect, margin: CGFloat) -> (CGSize) -> CGRect {
        { pageSize in
            let mapping = PageMapping(bounds: bounds, margin: margin, pageSize: pageSize)
            let corner = mapping.point(HorizontalPoint(x: region.minX, y: region.minY))
            return CGRect(
                x: corner.x,
                y: corner.y,
                width: max(CGFloat(region.width) * mapping.scale, 1),
                height: max(CGFloat(region.height) * mapping.scale, 1)
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
        crop: ((CGSize) -> CGRect)? = nil,
        overlay: ((CGContext, CGSize, CGFloat) -> Void)? = nil
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
        // Drawn in page points, over the page, with how many pixels a point is.
        overlay?(context, mediaBox.size, CGFloat(scale))
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
