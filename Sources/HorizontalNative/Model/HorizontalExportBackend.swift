#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import CoreGraphics
import Foundation
import HorizontalStepImporter
import SwiftUI

private let pdfPointsPerNanometer = CGFloat(72.0 / 25_400_000.0)

enum HorizontalExportBackend {
    static func export(
        sections: [HorizontalExportSection],
        settings: HorizontalExportSettings,
        project: HorizontalProject,
        schematicPDFPalette: HorizontalCanvasPalette = HorizontalCanvasPalette.defaultPalette(kind: .schematic, mode: .light),
        boardPDFPalette: HorizontalCanvasPalette = HorizontalCanvasPalette.defaultPalette(kind: .board, mode: .light),
        silkscreenClipping: HorizontalSilkscreenClipping? = nil
    ) -> HorizontalExportStatus {
        guard !sections.isEmpty else {
            return HorizontalExportStatus(kind: .warning, message: "No export sections are enabled.")
        }

        let targetURL: URL
        do {
            targetURL = try HorizontalExportSettings.exportTargetDirectory(
                for: project,
                requestedPath: settings.targetDirectory
            )
        } catch {
            return HorizontalExportStatus(kind: .error, message: error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        } catch {
            return HorizontalExportStatus(kind: .error, message: "Could not create target directory: \(error.localizedDescription)")
        }

        var messages = [String]()
        for section in sections {
            do {
                switch section {
                case .schematicPDF:
                    let url = targetURL.appendingPathComponent(settings.schematicPDF.filename)
                    try exportSchematicPDF(project: project, settings: settings.schematicPDF, palette: schematicPDFPalette, to: url)
                    messages.append("Schematic PDF -> \(url.lastPathComponent)")
                case .bom:
                    let url = targetURL.appendingPathComponent(settings.bom.filename)
                    try exportBOM(project: project, settings: settings.bom, to: url)
                    messages.append("BOM -> \(url.lastPathComponent)")
                case .gerber:
                    let urls = try exportGerber(project: project, settings: settings.gerber, to: targetURL, silkscreenClipping: silkscreenClipping)
                    messages.append("Gerber -> \(urls.map(\.lastPathComponent).joined(separator: ", "))")
                case .odb:
                    let url = try exportODB(project: project, settings: settings.odb, to: targetURL, silkscreenClipping: silkscreenClipping)
                    messages.append("ODB -> \(url.lastPathComponent)")
                case .pickAndPlace:
                    let urls = try exportPickAndPlace(project: project, settings: settings.pickAndPlace, to: targetURL)
                    messages.append("Pick and Place -> \(urls.map(\.lastPathComponent).joined(separator: ", "))")
                case .boardSTEP:
                    let url = targetURL.appendingPathComponent(settings.boardSTEP.filename)
                    try exportBoardSTEP(project: project, settings: settings.boardSTEP, to: url)
                    let note = settings.boardSTEP.include3DModels ? " (with component models)" : " (board body only)"
                    messages.append("3D Model -> \(url.lastPathComponent)\(note)")
                case .boardDrawing:
                    let url = targetURL.appendingPathComponent(settings.boardDrawing.filename)
                    try exportBoardDrawingPDF(project: project, settings: settings.boardDrawing, palette: boardPDFPalette, to: url, silkscreenClipping: silkscreenClipping)
                    messages.append("Board Drawing -> \(url.lastPathComponent)")
                case .boardDXF:
                    let url = targetURL.appendingPathComponent(settings.boardDXF.filename)
                    try exportBoardDXF(project: project, settings: settings.boardDXF, to: url, silkscreenClipping: silkscreenClipping)
                    messages.append("Board DXF -> \(url.lastPathComponent)")
                }
            } catch {
                return HorizontalExportStatus(kind: .error, message: "\(section.title): \(error.localizedDescription)")
            }
        }

        return HorizontalExportStatus(kind: .success, message: messages.joined(separator: " "))
    }

    private static func exportBOM(
        project: HorizontalProject,
        settings: HorizontalBOMExportSettings,
        to url: URL
    ) throws {
        let rows = bomRows(project: project, includeNoPopulate: settings.includeNoPopulate)
            .sorted { lhs, rhs in
                let result = lhs.value(for: settings.sortColumn).localizedStandardCompare(rhs.value(for: settings.sortColumn))
                return settings.sortOrder == .ascending ? result == .orderedAscending : result == .orderedDescending
            }
        let columns = orderedBOMColumns(settings.columns)
        let lines = [columns.map(\.title)] + rows.map { row in
            columns.map { row.value(for: $0) }
        }
        try writeCSV(lines, to: url)
    }

    private static func exportSchematicPDF(
        project: HorizontalProject,
        settings: HorizontalSchematicPDFExportSettings,
        palette: HorizontalCanvasPalette,
        to url: URL
    ) throws {
        let schematics = project.schematics.isEmpty
            ? project.schematic.map { [HorizontalProjectSchematic(block: HorizontalProjectBlock(uuid: $0.uuid, blockFilename: nil, schematicFilename: $0.url.lastPathComponent, symbolFilename: nil, isTop: true), schematicFilename: $0.url.lastPathComponent, schematic: $0)] } ?? []
            : project.schematics
        let sheets = schematics.flatMap { $0.schematic.sheets }
        guard !sheets.isEmpty else {
            throw HorizontalExportError("No schematic sheets loaded.")
        }

        let sheetsWithBounds = sheets.map { sheet in
            (sheet: sheet, bounds: schematicPageBounds(for: sheet))
        }
        let initialPageSize = sheetsWithBounds.first.map { pdfPageSize(for: $0.bounds) } ?? CGSize(width: 842, height: 595)

        try writePDF(to: url, title: "\(project.displayTitle) Schematic", initialPageSize: initialPageSize) { context, _ in
            for entry in sheetsWithBounds {
                let pageSize = pdfPageSize(for: entry.bounds)
                let transform = PDFWorldTransform(bounds: entry.bounds, pageSize: pageSize, margin: 0)
                context.beginPDFPage(pdfPageInfo(pageSize: pageSize))
                drawSchematicSheet(
                    entry.sheet,
                    context: context,
                    transform: transform,
                    palette: palette,
                    minimumLineWidthMM: settings.minimumLineWidthMM
                )
                context.endPDFPage()
            }
        }
    }

    private static func exportBoardDrawingPDF(
        project: HorizontalProject,
        settings: HorizontalBoardDrawingExportSettings,
        palette: HorizontalCanvasPalette,
        to url: URL,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil
    ) throws {
        guard let board = project.board else {
            throw HorizontalExportError("No board loaded.")
        }

        let layerSettings = Dictionary(uniqueKeysWithValues: settings.layers.map { ($0.layer, $0) })
        try writePDF(to: url, title: "\(project.displayTitle) Board") { context, pageSize in
            let bounds = (board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds).padded(0.08)
            let transform = PDFWorldTransform(bounds: bounds, pageSize: pageSize)
            context.beginPDFPage(nil)
            drawBoard(
                board,
                context: context,
                transform: transform,
                palette: palette,
                layerSettings: layerSettings,
                minimumLineWidthMM: settings.minimumLineWidthMM,
                silkscreenClipping: silkscreenClipping
            )
            context.endPDFPage()
        }
    }

    private static func exportBoardDXF(
        project: HorizontalProject,
        settings: HorizontalBoardDXFExportSettings,
        to url: URL,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil
    ) throws {
        guard let board = project.board else {
            throw HorizontalExportError("No board loaded.")
        }

        let layerSettings = Dictionary(uniqueKeysWithValues: settings.layers.map { ($0.layer, $0) })
        let defaultWidth = max(settings.minimumLineWidthMM * 1_000_000, 80_000)
        var writer = HorizontalDXFWriter()
        let clippedSilk = silkscreenClipping.map { clipping in
            HorizontalSilkscreenClipper.clip(board: board, clipping: clipping)
        } ?? [:]
        func addClippedSilk(_ id: String, layer: Int?, setting: HorizontalExportLayerSetting) -> Bool {
            guard let layer, let clipped = clippedSilk[layer]?.object(id) else {
                return false
            }
            for fragment in clipped.fragments {
                let contour = HorizontalSilkscreenClipper.bridgedContour(fragment)
                guard contour.count >= 3 else { continue }
                writer.addClosedPolygon(
                    contour,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    fill: true,
                    outlineWidth: defaultWidth
                )
            }
            return true
        }

        for setting in settings.layers {
            writer.addLayer(dxfLayerName(for: setting), color: setting.color)
        }
        if settings.includeHoles {
            writer.addLayer("Holes", color: HorizontalRGBColor(red: 0.75, green: 0.75, blue: 0.75))
        }
        if settings.includeDimensions {
            writer.addLayer("Dimensions", color: HorizontalRGBColor(red: 0, green: 0, blue: 0))
        }

        func setting(for layer: Int?) -> HorizontalExportLayerSetting? {
            guard let layer, let setting = layerSettings[layer] else {
                return nil
            }
            return setting
        }

        func appendText(_ text: HorizontalText, setting: HorizontalExportLayerSetting) {
            for (from, to) in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                writer.addPolyline(
                    [from, to],
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    width: max(text.width, defaultWidth)
                )
            }
        }

        func traceWidth(_ width: Double) -> Double {
            width > 0 ? width : defaultWidth
        }

        func addCopperAwareStroke(
            _ points: [HorizontalPoint],
            setting: HorizontalExportLayerSetting,
            width: Double
        ) {
            let layerName = dxfLayerName(for: setting)
            if HorizontalBoardLayers.isCopper(setting.layer) {
                writer.addGerberApertureStroke(
                    points,
                    layer: layerName,
                    color: setting.color,
                    width: width,
                    fill: setting.mode == .fill,
                    outlineWidth: defaultWidth
                )
            } else {
                writer.addPolyline(
                    points,
                    layer: layerName,
                    color: setting.color,
                    width: width
                )
            }
        }

        for plane in board.planes {
            guard let setting = setting(for: plane.layer) else { continue }
            for fragment in plane.renderFragments {
                for path in fragment.paths where path.count >= 3 {
                    writer.addClosedPolygon(
                        path,
                        layer: dxfLayerName(for: setting),
                        color: setting.color,
                        fill: setting.mode == .fill && !HorizontalBoardLayers.isCopper(setting.layer),
                        outlineWidth: defaultWidth
                    )
                }
            }
        }

        for polygon in board.polygons + board.packagePolygons {
            let vertices = polygon.renderVertices(arcPrecision: 32)
            guard let setting = setting(for: polygon.layer), vertices.count >= 3 else { continue }
            if addClippedSilk(polygon.id, layer: polygon.layer, setting: setting) { continue }
            writer.addClosedPolygon(
                vertices,
                layer: dxfLayerName(for: setting),
                color: setting.color,
                fill: setting.mode == .fill,
                outlineWidth: defaultWidth
            )
        }
        for pad in horizonPadOutlineFragments(board.packagePads) {
            guard let setting = setting(for: pad.layer) else { continue }
            for path in pad.paths where path.count >= 3 {
                writer.addClosedPolygon(
                    path,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    fill: setting.mode == .fill,
                    outlineWidth: defaultWidth
                )
            }
        }
        for via in board.vias {
            let ring = via.ringOutline()
            if ring.count >= 3 {
                for layer in via.copperLayers {
                    guard let setting = setting(for: layer) else { continue }
                    writer.addClosedPolygon(
                        ring,
                        layer: dxfLayerName(for: setting),
                        color: setting.color,
                        fill: setting.mode == .fill,
                        outlineWidth: defaultWidth
                    )
                }
            }
            for layer in via.maskLayers {
                let opening = via.maskOutline(on: layer)
                guard opening.count >= 3, let setting = setting(for: layer) else { continue }
                writer.addClosedPolygon(
                    opening,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    fill: setting.mode == .fill,
                    outlineWidth: defaultWidth
                )
            }
        }

        appendDerivedDXFPadLayer(
            targetLayer: HorizontalBoardLayers.topMask,
            sourceLayer: HorizontalBoardLayers.topCopper,
            board: board,
            setting: setting(for: HorizontalBoardLayers.topMask),
            writer: &writer,
            defaultWidth: defaultWidth
        )
        appendDerivedDXFPadLayer(
            targetLayer: HorizontalBoardLayers.bottomMask,
            sourceLayer: HorizontalBoardLayers.bottomCopper,
            board: board,
            setting: setting(for: HorizontalBoardLayers.bottomMask),
            writer: &writer,
            defaultWidth: defaultWidth
        )
        appendDerivedDXFPadLayer(
            targetLayer: HorizontalBoardLayers.topPaste,
            sourceLayer: HorizontalBoardLayers.topCopper,
            board: board,
            setting: setting(for: HorizontalBoardLayers.topPaste),
            writer: &writer,
            defaultWidth: defaultWidth
        )
        appendDerivedDXFPadLayer(
            targetLayer: HorizontalBoardLayers.bottomPaste,
            sourceLayer: HorizontalBoardLayers.bottomCopper,
            board: board,
            setting: setting(for: HorizontalBoardLayers.bottomPaste),
            writer: &writer,
            defaultWidth: defaultWidth
        )

        for keepout in board.keepouts {
            let vertices = keepout.polygon.renderVertices(arcPrecision: 32)
            guard let setting = setting(for: keepout.polygon.layer), vertices.count >= 3 else { continue }
            writer.addPolyline(
                vertices,
                layer: dxfLayerName(for: setting),
                color: setting.color,
                width: defaultWidth,
                closed: true
            )
        }

        for segment in board.tracks + board.netTies {
            guard let setting = setting(for: segment.layer) else { continue }
            if HorizontalBoardLayers.isCopper(setting.layer) {
                writer.addGerberApertureStroke(
                    segment.pathPoints,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    width: traceWidth(segment.width),
                    fill: setting.mode == .fill,
                    outlineWidth: defaultWidth
                )
            } else if let arc = segment.arc {
                writer.addArc(
                    arc,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    width: traceWidth(segment.width)
                )
            } else {
                writer.addPolyline(
                    segment.pathPoints,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    width: traceWidth(segment.width)
                )
            }
        }

        for segment in board.lines + board.packageLines {
            guard let setting = setting(for: segment.layer) else { continue }
            if addClippedSilk(segment.id, layer: segment.layer, setting: setting) { continue }
            addCopperAwareStroke(
                segment.pathPoints,
                setting: setting,
                width: max(segment.width, defaultWidth)
            )
        }

        for arc in board.arcs + board.packageArcs {
            guard let setting = setting(for: arc.layer) else { continue }
            if addClippedSilk(arc.id, layer: arc.layer, setting: setting) { continue }
            let width = HorizontalBoardLayers.isCopper(setting.layer) ? traceWidth(arc.width) : max(arc.width, defaultWidth)
            if HorizontalBoardLayers.isCopper(setting.layer) {
                addCopperAwareStroke(arc.polyline(), setting: setting, width: width)
            } else {
                writer.addArc(
                    arc,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    width: width
                )
            }
        }

        for decal in board.decals {
            for polygon in decal.polygons {
                let vertices = polygon.renderVertices(arcPrecision: 32)
                guard let setting = setting(for: polygon.layer), vertices.count >= 3 else { continue }
                if addClippedSilk(polygon.id, layer: polygon.layer, setting: setting) { continue }
                writer.addClosedPolygon(
                    vertices,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    fill: setting.mode == .fill,
                    outlineWidth: defaultWidth
                )
            }
            for line in decal.lines {
                guard let setting = setting(for: line.layer) else { continue }
                if addClippedSilk(line.id, layer: line.layer, setting: setting) { continue }
                addCopperAwareStroke(
                    line.pathPoints,
                    setting: setting,
                    width: max(line.width, defaultWidth)
                )
            }
            for arc in decal.arcs {
                guard let setting = setting(for: arc.layer) else { continue }
                if addClippedSilk(arc.id, layer: arc.layer, setting: setting) { continue }
                let width = max(arc.width, defaultWidth)
                if HorizontalBoardLayers.isCopper(setting.layer) {
                    addCopperAwareStroke(arc.polyline(), setting: setting, width: width)
                } else {
                    writer.addArc(
                        arc,
                        layer: dxfLayerName(for: setting),
                        color: setting.color,
                        width: width
                    )
                }
            }
            for text in decal.texts {
                guard let setting = setting(for: text.layer) else { continue }
                if addClippedSilk(text.id, layer: text.layer, setting: setting) { continue }
                appendText(text, setting: setting)
            }
        }

        for text in board.texts + board.packageTexts {
            guard let setting = setting(for: text.layer) else { continue }
            if addClippedSilk(text.id, layer: text.layer, setting: setting) { continue }
            appendText(text, setting: setting)
        }

        if settings.includeDimensions {
            appendDXFDimensions(board.dimensions, writer: &writer, width: defaultWidth)
        }

        if settings.includeHoles {
            for hole in board.holes + board.viaHoles + board.packageHoles {
                if hole.shape == .slot, hole.effectiveLength > hole.diameter {
                    writer.addPolyline(
                        hole.outlinePoints(),
                        layer: "Holes",
                        color: HorizontalRGBColor(red: 0.75, green: 0.75, blue: 0.75),
                        width: defaultWidth,
                        closed: true
                    )
                } else {
                    writer.addCircle(
                        center: hole.position,
                        radius: hole.diameter / 2,
                        layer: "Holes",
                        color: HorizontalRGBColor(red: 0.75, green: 0.75, blue: 0.75),
                        width: defaultWidth
                    )
                }
            }
        }

        try writer.write(to: url)
    }

    private static func dxfLayerName(for setting: HorizontalExportLayerSetting) -> String {
        let sanitizedName = setting.name
            .components(separatedBy: CharacterSet(charactersIn: "<>/\\\":;?*|=`,"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sanitizedName.isEmpty ? HorizontalBoardLayers.name(for: setting.layer) : sanitizedName
        return "\(name) (\(setting.layer))"
    }

    private static func appendDerivedDXFPadLayer(
        targetLayer: Int,
        sourceLayer: Int,
        board: HorizontalBoard,
        setting: HorizontalExportLayerSetting?,
        writer: inout HorizontalDXFWriter,
        defaultWidth: Double
    ) {
        guard let setting else {
            return
        }

        let hasExplicitGeometry = (board.polygons + board.packagePolygons + board.packagePads)
            .contains { $0.layer == targetLayer && $0.renderVertices(arcPrecision: 32).count >= 3 }
        guard !hasExplicitGeometry else {
            return
        }

        for pad in horizonPadOutlineFragments(board.packagePads).filter({ $0.layer == sourceLayer }) {
            for path in pad.paths where path.count >= 3 {
                writer.addClosedPolygon(
                    path,
                    layer: dxfLayerName(for: setting),
                    color: setting.color,
                    fill: setting.mode == .fill,
                    outlineWidth: defaultWidth
                )
            }
        }
    }

    private static func bomRows(project: HorizontalProject, includeNoPopulate: Bool) -> [BOMRow] {
        var componentsByID = [String: SchematicComponentInfo]()
        for schematic in project.schematics {
            for sheet in schematic.schematic.sheets {
                for (componentID, component) in sheet.componentInfo {
                    componentsByID[normalizedID(componentID)] = component
                }
            }
        }
        if componentsByID.isEmpty, let schematic = project.schematic {
            for sheet in schematic.sheets {
                for (componentID, component) in sheet.componentInfo {
                    componentsByID[normalizedID(componentID)] = component
                }
            }
        }

        var rowsByKey = [BOMRowKey: BOMRow]()
        for component in componentsByID.values {
            guard includeNoPopulate || !component.noPopulate else {
                continue
            }
            let details = component.details
            let key = BOMRowKey(
                mpn: nonEmpty(details?.mpn) ?? nonEmpty(component.partID) ?? "",
                value: nonEmpty(component.value) ?? nonEmpty(details?.value) ?? "",
                manufacturer: nonEmpty(details?.manufacturer) ?? "",
                packageName: nonEmpty(details?.packageName) ?? "",
                description: nonEmpty(details?.description) ?? "",
                datasheet: nonEmpty(details?.datasheet) ?? ""
            )
            var row = rowsByKey[key] ?? BOMRow(key: key, refdes: [])
            if let refdes = nonEmpty(component.refdes) {
                row.refdes.append(refdes)
            }
            rowsByKey[key] = row
        }

        return rowsByKey.values.map { row in
            var row = row
            row.refdes.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            return row
        }
    }

    private static func exportPickAndPlace(
        project: HorizontalProject,
        settings: HorizontalPnPExportSettings,
        to directoryURL: URL
    ) throws -> [URL] {
        guard let board = project.board else {
            throw HorizontalExportError("No board loaded.")
        }

        let rows = board.packages.compactMap { package -> PnPRow? in
            guard settings.includeNoPopulate || package.componentDetails?.noPopulate != true else {
                return nil
            }
            return PnPRow(package: package, settings: settings)
        }.sorted {
            $0.refdes.localizedStandardCompare($1.refdes) == .orderedAscending
        }
        let columns = orderedPnPColumns(settings.columns)

        func write(_ rows: [PnPRow], filename: String) throws -> URL {
            let url = directoryURL.appendingPathComponent(filename)
            let lines = [columns.map(\.title)] + rows.map { row in
                columns.map { row.value(for: $0) }
            }
            try writeCSV(lines, to: url)
            return url
        }

        switch settings.mode {
        case .merged:
            return [try write(rows, filename: settings.filenameMerged)]
        case .individual:
            return [
                try write(rows.filter { $0.side == settings.topSide }, filename: settings.filenameTop),
                try write(rows.filter { $0.side == settings.bottomSide }, filename: settings.filenameBottom)
            ]
        }
    }

    /// Internal (not private) so the Gerber tests can drive it directly.
    static func exportGerber(
        project: HorizontalProject,
        settings: HorizontalGerberExportSettings,
        to directoryURL: URL,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil
    ) throws -> [URL] {
        guard let board = project.board else {
            throw HorizontalExportError("No board loaded.")
        }

        let prefix = nonEmpty(settings.prefix) ?? HorizontalExportSettings.sanitizedFilename(project.displayTitle)
        var written = [URL]()
        for layer in settings.layers where layer.enabled {
            let layerObjects = gerberObjects(for: board, layer: layer.layer, outlineWidthMM: settings.outlineWidthMM, silkscreenClipping: silkscreenClipping)
            guard !layerObjects.isEmpty else {
                continue
            }
            let suffix = nonBlankPreservingWhitespace(layer.filename) ?? " \(HorizontalBoardLayers.name(for: layer.layer)).gbr"
            let url = directoryURL.appendingPathComponent("\(prefix)\(suffix)")
            try writeGerberLayer(layerObjects, layerName: layer.name, to: url)
            written.append(url)
        }

        let drillURLs = try writeDrillFiles(board: board, settings: settings, prefix: prefix, to: directoryURL)
        written.append(contentsOf: drillURLs)

        let staleManifestURL = directoryURL.appendingPathComponent("\(prefix)-gerber-files.txt")
        if FileManager.default.fileExists(atPath: staleManifestURL.path) {
            try FileManager.default.removeItem(at: staleManifestURL)
        }

        guard !written.isEmpty else {
            throw HorizontalExportError("No Gerber layers or drills were generated.")
        }

        if settings.zipOutput {
            let zipURL = directoryURL.appendingPathComponent("\(prefix).zip")
            try writeFlatZip(files: written, to: zipURL)
            if settings.removeIndividualFilesAfterZip {
                for url in written where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return [zipURL]
            }
            written.append(zipURL)
        }

        return written
    }

    private static func writeFlatZip(files: [URL], to url: URL) throws {
        guard !files.isEmpty else {
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let entries = try HorizontalArchiveWriter.flatFileEntries(files)
        try HorizontalArchiveWriter.zipData(entries: entries).write(to: url)
    }

    private static func exportODB(
        project: HorizontalProject,
        settings: HorizontalODBExportSettings,
        to directoryURL: URL,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil
    ) throws -> URL {
        guard let board = project.board else {
            throw HorizontalExportError("No board loaded.")
        }

        let jobName = odbLegalEntityName(nonEmpty(settings.jobName) ?? project.displayTitle)
        let fileManager = FileManager.default

        switch settings.format {
        case .directory:
            let directoryName = nonEmpty(settings.directoryName) ?? jobName
            let jobURL = directoryURL.appendingPathComponent(directoryName, isDirectory: true)
            if fileManager.fileExists(atPath: jobURL.path) {
                try fileManager.removeItem(at: jobURL)
            }
            try writeODBJob(project: project, board: board, jobName: jobName, to: jobURL, silkscreenClipping: silkscreenClipping)
            return jobURL
        case .tgz, .zip:
            let filename = nonEmpty(settings.filename) ?? "\(jobName).\(settings.format == .tgz ? "tgz" : "zip")"
            let outputURL = directoryURL.appendingPathComponent(filename)
            let scratchRoot = fileManager.temporaryDirectory
                .appendingPathComponent("Horizontal-ODB-\(UUID().uuidString)", isDirectory: true)
            let jobURL = scratchRoot.appendingPathComponent(jobName, isDirectory: true)
            try writeODBJob(project: project, board: board, jobName: jobName, to: jobURL, silkscreenClipping: silkscreenClipping)
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            switch settings.format {
            case .tgz:
                let entries = try HorizontalArchiveWriter.directoryTreeEntries(root: jobURL, topLevelName: jobName)
                try HorizontalArchiveWriter.targzData(entries: entries).write(to: outputURL)
            case .zip:
                let entries = try HorizontalArchiveWriter.directoryTreeEntries(root: jobURL, topLevelName: jobName)
                try HorizontalArchiveWriter.zipData(entries: entries).write(to: outputURL)
            case .directory:
                break
            }
            try? fileManager.removeItem(at: scratchRoot)
            return outputURL
        }
    }

    private static func exportBoardSTEP(
        project: HorizontalProject,
        settings: HorizontalSTEPExportSettings,
        to url: URL
    ) throws {
        guard let board = project.board else {
            throw HorizontalExportError("No board loaded.")
        }
        let outline = boardProfileContours(for: board).first ?? []
        guard outline.count >= 3 else {
            throw HorizontalExportError("No board outline available.")
        }

        let outlinePoints = outline.map { point in
            HNStepPoint(x: point.x / 1_000_000, y: point.y / 1_000_000)
        }
        let minimumHoleDiameter = max(settings.minimumHoleDiameterMM, 0)
        let holes = (board.holes + board.viaHoles + board.packageHoles)
            .filter { $0.diameter / 1_000_000 >= minimumHoleDiameter }
            .map { hole in
                HNStepHole(
                    x: hole.position.x / 1_000_000,
                    y: hole.position.y / 1_000_000,
                    diameter: hole.diameter / 1_000_000,
                    plated: hole.plated
                )
            }
        let thicknessMM = max(board.totalSubstrateThickness / 1_000_000, 0.2)
        let label = nonEmpty(settings.labelPrefix) ?? project.displayTitle

        // Gather placed component 3D models. C-string storage is held alive until
        // after the export call by `cStringAllocations` (freed in the defer).
        var cStringAllocations = [UnsafeMutablePointer<CChar>]()
        defer { cStringAllocations.forEach { free($0) } }
        func cString(_ value: String) -> UnsafePointer<CChar> {
            let duplicate = strdup(value) ?? UnsafeMutablePointer<CChar>.allocate(capacity: 1)
            cStringAllocations.append(duplicate)
            return UnsafePointer(duplicate)
        }
        func radians(_ horizonAngle: Int) -> Double {
            Double(horizonAngle) / 65_536.0 * Double.pi * 2
        }

        var modelInstances = [HNStepModelInstance]()
        if settings.include3DModels {
            for package in board.packages {
                guard let model = package.model3D else { continue }
                if package.componentDetails?.noPopulate == true { continue }
                let modelPath = model.fileURL.path
                guard !modelPath.isEmpty,
                      FileManager.default.fileExists(atPath: modelPath) else { continue }
                let refdes = nonEmpty(package.componentDetails?.refdes) ?? package.label
                modelInstances.append(HNStepModelInstance(
                    path: cString(modelPath),
                    name: cString(refdes),
                    posX: package.position.x / 1_000_000,
                    posY: package.position.y / 1_000_000,
                    rotation: radians(package.angle),
                    bottom: package.mirrored,
                    offsetX: model.x / 1_000_000,
                    offsetY: model.y / 1_000_000,
                    offsetZ: model.z / 1_000_000,
                    orientRoll: radians(model.roll),
                    orientPitch: radians(model.pitch),
                    orientYaw: radians(model.yaw)
                ))
            }
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let success = url.path.withCString { pathPointer in
            label.withCString { labelPointer in
                outlinePoints.withUnsafeBufferPointer { outlineBuffer in
                    holes.withUnsafeBufferPointer { holeBuffer in
                        modelInstances.withUnsafeBufferPointer { modelBuffer in
                            HNStepExportBoardWithModels(
                                pathPointer,
                                outlineBuffer.baseAddress,
                                UInt32(outlineBuffer.count),
                                holeBuffer.baseAddress,
                                UInt32(holeBuffer.count),
                                thicknessMM,
                                labelPointer,
                                modelBuffer.baseAddress,
                                UInt32(modelBuffer.count)
                            )
                        }
                    }
                }
            }
        }
        guard success else {
            throw HorizontalExportError("OCCT could not write the board STEP file.")
        }
    }

    private static func writePDF(
        to url: URL,
        title: String,
        initialPageSize: CGSize = CGSize(width: 842, height: 595),
        render: (CGContext, CGSize) throws -> Void
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var mediaBox = CGRect(origin: .zero, size: initialPageSize)
        guard let context = CGContext(
            url as CFURL,
            mediaBox: &mediaBox,
            [
                kCGPDFContextTitle as String: title,
                kCGPDFContextCreator as String: "Horizontal"
            ] as CFDictionary
        ) else {
            throw HorizontalExportError("Could not create PDF context.")
        }
        try render(context, mediaBox.size)
        context.closePDF()
    }

    private static func pdfPageInfo(pageSize: CGSize) -> CFDictionary {
        let mediaBox = CGRect(origin: .zero, size: pageSize)
        let mediaBoxData = withUnsafeBytes(of: mediaBox) { Data($0) } as NSData
        return [kCGPDFContextMediaBox as String: mediaBoxData] as CFDictionary
    }

    private static func pdfPageSize(for bounds: HorizontalRect) -> CGSize {
        CGSize(
            width: max(CGFloat(max(bounds.width, 1)) * pdfPointsPerNanometer, 1),
            height: max(CGFloat(max(bounds.height, 1)) * pdfPointsPerNanometer, 1)
        )
    }

    private static func drawSchematicSheet(
        _ sheet: HorizontalSchematicSheet,
        context: CGContext,
        transform: PDFWorldTransform,
        palette: HorizontalCanvasPalette,
        minimumLineWidthMM: Double
    ) {
        let symbolColor = rgbColor(from: palette.pin)
        let annotationColor = rgbColor(from: palette.pinAnnotation)
        let netColor = rgbColor(from: palette.net)
        let busColor = rgbColor(from: palette.bus)
        let frameColor = rgbColor(from: palette.frame)
        let drawingColor = symbolColor
        let lineWidth = max(minimumLineWidthMM * 1_000_000, 80_000)

        context.setFillColor(rgbColor(from: palette.background).cgColor(alpha: 1))
        context.fill(CGRect(origin: .zero, size: transform.pageSize))

        drawSegments(sheet.frameLines, color: frameColor, width: lineWidth, context: context, transform: transform)
        drawPolygons(sheet.framePolygons, color: frameColor, context: context, transform: transform, fill: false, width: lineWidth)
        drawTexts(sheet.frameTexts, color: frameColor, context: context, transform: transform, width: lineWidth)
        drawSegments(sheet.drawingLines, color: drawingColor, width: lineWidth, context: context, transform: transform)
        drawArcs(sheet.drawingArcs, color: drawingColor, width: lineWidth, context: context, transform: transform)
        drawSegments(sheet.blockSymbolLines, color: symbolColor, width: lineWidth, context: context, transform: transform)
        drawSegments(sheet.blockSymbolPorts, color: symbolColor, width: lineWidth, context: context, transform: transform)
        drawTexts(sheet.blockSymbolTexts, color: annotationColor, context: context, transform: transform, width: lineWidth)
        drawPolygons(sheet.symbolPolygons, color: symbolColor, context: context, transform: transform, fill: false, width: lineWidth)
        drawSegments(sheet.symbolLines, color: symbolColor, width: lineWidth, context: context, transform: transform)
        drawSegments(sheet.symbolPins, color: symbolColor, width: lineWidth, context: context, transform: transform)
        drawCircles(sheet.symbolPinCircles, color: symbolColor, context: context, transform: transform, width: lineWidth)
        drawTexts(sheet.symbolTexts, color: annotationColor, context: context, transform: transform, width: lineWidth)
        drawSegments(sheet.netLines, color: netColor, width: max(lineWidth, 140_000), context: context, transform: transform)
        drawNetLabels(sheet.netLabels, color: netColor, context: context, transform: transform, width: lineWidth)
        drawBusLabels(sheet.busLabels, color: busColor, context: context, transform: transform, width: lineWidth)
        drawSegments(sheet.busRipperLines, color: busColor, width: lineWidth, context: context, transform: transform)
        drawTexts(sheet.busRipperTexts, color: busColor, context: context, transform: transform, width: lineWidth)
        drawSegments(sheet.powerSymbolLines, color: symbolColor, width: lineWidth, context: context, transform: transform)
        drawCircles(sheet.powerSymbolCircles, color: symbolColor, context: context, transform: transform, width: lineWidth)
        drawTexts(sheet.powerSymbolTexts, color: symbolColor, context: context, transform: transform, width: lineWidth)
        drawTexts(sheet.texts, color: drawingColor, context: context, transform: transform, width: lineWidth)
    }

    private static func drawBoard(
        _ board: HorizontalBoard,
        context: CGContext,
        transform: PDFWorldTransform,
        palette: HorizontalCanvasPalette,
        layerSettings: [Int: HorizontalExportLayerSetting],
        minimumLineWidthMM: Double,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil
    ) {
        context.setFillColor(rgbColor(from: palette.background).cgColor(alpha: 1))
        context.fill(CGRect(origin: .zero, size: transform.pageSize))
        let defaultWidth = max(minimumLineWidthMM * 1_000_000, 80_000)
        let clippedSilk = silkscreenClipping.map { clipping in
            HorizontalSilkscreenClipper.clip(board: board, clipping: clipping)
        } ?? [:]
        func drawClippedSilk(_ id: String, layer: Int?, setting: HorizontalExportLayerSetting) -> Bool {
            guard let layer, let clipped = clippedSilk[layer]?.object(id) else {
                return false
            }
            for fragment in clipped.fragments {
                let contour = HorizontalSilkscreenClipper.bridgedContour(fragment)
                guard contour.count >= 3 else { continue }
                drawPolygonVertices(contour, color: setting.color, context: context, transform: transform, fill: true, width: defaultWidth)
            }
            return true
        }

        func setting(for layer: Int?) -> HorizontalExportLayerSetting? {
            guard let layer, let setting = layerSettings[layer], setting.enabled else {
                return nil
            }
            return setting
        }

        for plane in board.planes {
            guard let setting = setting(for: plane.layer) else { continue }
            for fragment in plane.renderFragments {
                for path in fragment.paths {
                    drawPolygonVertices(path, color: setting.color, context: context, transform: transform, fill: true, width: defaultWidth, alpha: 0.28)
                }
            }
        }
        for polygon in board.polygons + board.packagePolygons {
            guard let setting = setting(for: polygon.layer) else { continue }
            if drawClippedSilk(polygon.id, layer: polygon.layer, setting: setting) { continue }
            drawPolygonVertices(polygon.renderVertices(arcPrecision: 32), color: setting.color, context: context, transform: transform, fill: setting.mode == .fill, width: defaultWidth)
        }
        for pad in horizonPadOutlineFragments(board.packagePads) {
            guard let setting = setting(for: pad.layer) else { continue }
            for path in pad.paths where path.count >= 3 {
                drawPolygonVertices(path, color: setting.color, context: context, transform: transform, fill: setting.mode == .fill, width: defaultWidth)
            }
        }
        for via in board.vias {
            let ring = via.ringOutline()
            if ring.count >= 3 {
                for layer in via.copperLayers {
                    guard let setting = setting(for: layer) else { continue }
                    drawPolygonVertices(ring, color: setting.color, context: context, transform: transform, fill: setting.mode == .fill, width: defaultWidth)
                }
            }
            for layer in via.maskLayers {
                let opening = via.maskOutline(on: layer)
                guard opening.count >= 3, let setting = setting(for: layer) else { continue }
                drawPolygonVertices(opening, color: setting.color, context: context, transform: transform, fill: setting.mode == .fill, width: defaultWidth)
            }
        }
        for keepout in board.keepouts {
            guard let setting = setting(for: keepout.polygon.layer) else { continue }
            drawPolygonVertices(keepout.polygon.renderVertices(arcPrecision: 32), color: setting.color, context: context, transform: transform, fill: false, width: defaultWidth, alpha: 0.7)
        }
        for segment in board.tracks + board.netTies + board.lines + board.packageLines {
            guard let setting = setting(for: segment.layer) else { continue }
            if drawClippedSilk(segment.id, layer: segment.layer, setting: setting) { continue }
            drawSegment(segment, color: setting.color, width: max(segment.width, defaultWidth), context: context, transform: transform)
        }
        for arc in board.arcs + board.packageArcs {
            guard let setting = setting(for: arc.layer) else { continue }
            if drawClippedSilk(arc.id, layer: arc.layer, setting: setting) { continue }
            drawArc(arc, color: setting.color, width: max(arc.width, defaultWidth), context: context, transform: transform)
        }
        for decal in board.decals {
            for polygon in decal.polygons {
                guard let setting = setting(for: polygon.layer) else { continue }
                if drawClippedSilk(polygon.id, layer: polygon.layer, setting: setting) { continue }
                drawPolygonVertices(polygon.renderVertices(arcPrecision: 32), color: setting.color, context: context, transform: transform, fill: setting.mode == .fill, width: defaultWidth)
            }
            for line in decal.lines {
                guard let setting = setting(for: line.layer) else { continue }
                if drawClippedSilk(line.id, layer: line.layer, setting: setting) { continue }
                drawSegment(line, color: setting.color, width: max(line.width, defaultWidth), context: context, transform: transform)
            }
            for arc in decal.arcs {
                guard let setting = setting(for: arc.layer) else { continue }
                if drawClippedSilk(arc.id, layer: arc.layer, setting: setting) { continue }
                drawArc(arc, color: setting.color, width: max(arc.width, defaultWidth), context: context, transform: transform)
            }
            for text in decal.texts {
                guard let setting = setting(for: text.layer) else { continue }
                if drawClippedSilk(text.id, layer: text.layer, setting: setting) { continue }
                drawText(text, color: setting.color, context: context, transform: transform, width: defaultWidth)
            }
        }
        for text in board.texts + board.packageTexts {
            guard let setting = setting(for: text.layer) else { continue }
            if drawClippedSilk(text.id, layer: text.layer, setting: setting) { continue }
            drawText(text, color: setting.color, context: context, transform: transform, width: defaultWidth)
        }
        drawDimensions(board.dimensions, color: rgbColor(from: palette.layerColor(for: HorizontalBoardLayers.dimensions)), context: context, transform: transform, width: defaultWidth)
        for hole in board.holes + board.viaHoles + board.packageHoles {
            drawCircle(center: hole.position, radius: hole.diameter / 2, color: HorizontalRGBColor(red: 0.95, green: 0.95, blue: 0.95), context: context, transform: transform, width: defaultWidth)
        }
    }

    private static func writeCSV(_ rows: [[String]], to url: URL) throws {
        let csv = rows.map { row in
            row.map(csvEscaped).joined(separator: ",")
        }.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(csv.utf8).write(to: url, options: [.atomic])
    }

    private static func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func orderedBOMColumns(_ selected: Set<HorizontalBOMColumn>) -> [HorizontalBOMColumn] {
        let columns = HorizontalBOMColumn.allCases.filter { selected.contains($0) }
        return columns.isEmpty ? [.quantity, .mpn, .value, .manufacturer, .refdes] : columns
    }

    private static func orderedPnPColumns(_ selected: Set<HorizontalPnPColumn>) -> [HorizontalPnPColumn] {
        let columns = HorizontalPnPColumn.allCases.filter { selected.contains($0) }
        return columns.isEmpty ? [.refdes, .x, .y, .angle, .side] : columns
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonBlankPreservingWhitespace(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private static func normalizedID(_ id: String) -> String {
        id.lowercased()
    }

    private static func schematicBounds(for sheet: HorizontalSchematicSheet) -> HorizontalRect {
        var points = [HorizontalPoint]()
        points += sheet.frameLines.flatMap { [$0.from, $0.to] }
        points += sheet.framePolygons.flatMap { $0.renderVertices(arcPrecision: 32) }
        points += sheet.frameTexts.flatMap(\.renderBoundsPoints)
        points += sheet.drawingLines.flatMap { [$0.from, $0.to] }
        points += sheet.drawingArcs.flatMap { $0.polyline() }
        points += sheet.blockSymbolLines.flatMap { [$0.from, $0.to] }
        points += sheet.blockSymbolPorts.flatMap { [$0.from, $0.to] }
        points += sheet.blockSymbolTexts.flatMap(\.renderBoundsPoints)
        points += sheet.symbolPolygons.flatMap { $0.renderVertices(arcPrecision: 32) }
        points += sheet.symbolLines.flatMap { [$0.from, $0.to] }
        points += sheet.symbolPins.flatMap { [$0.from, $0.to] }
        points += sheet.symbolPinCircles.flatMap { circleBoundsPoints(center: $0.center, radius: $0.radius) }
        points += sheet.symbolTexts.flatMap(\.renderBoundsPoints)
        points += sheet.netLines.flatMap { [$0.from, $0.to] }
        points += sheet.netLabels.flatMap { labelBoundsPoints(id: $0.id, text: $0.text, position: $0.position, size: $0.size, orientation: $0.orientation) }
        points += sheet.busLabels.flatMap { labelBoundsPoints(id: $0.id, text: $0.text, position: $0.position, size: $0.size, orientation: $0.orientation) }
        points += sheet.busRipperLines.flatMap { [$0.from, $0.to] }
        points += sheet.busRipperTexts.flatMap(\.renderBoundsPoints)
        points += sheet.powerSymbolLines.flatMap { [$0.from, $0.to] }
        points += sheet.powerSymbolCircles.flatMap { circleBoundsPoints(center: $0.center, radius: $0.radius) }
        points += sheet.powerSymbolTexts.flatMap(\.renderBoundsPoints)
        points += sheet.texts.flatMap(\.renderBoundsPoints)
        let bounds = HorizontalRect(points: points)
        return bounds.isEmpty ? sheet.bounds : bounds
    }

    private static func schematicPageBounds(for sheet: HorizontalSchematicSheet) -> HorizontalRect {
        let framePoints = sheet.frameLines.flatMap { [$0.from, $0.to] }
            + sheet.framePolygons.flatMap { $0.renderVertices(arcPrecision: 32) }
        let frameBounds = HorizontalRect(points: framePoints)
        if !frameBounds.isEmpty && frameBounds.width > 0 && frameBounds.height > 0 {
            return frameBounds
        }

        let contentBounds = schematicBounds(for: sheet)
        if !contentBounds.isEmpty {
            return contentBounds.padded(0.02)
        }
        return sheet.bounds
    }

    private static func drawSegments(
        _ segments: [HorizontalSegment],
        color: HorizontalRGBColor,
        width: Double,
        context: CGContext,
        transform: PDFWorldTransform
    ) {
        for segment in segments {
            drawSegment(segment, color: color, width: max(segment.width, width), context: context, transform: transform)
        }
    }

    private static func drawSegment(
        _ segment: HorizontalSegment,
        color: HorizontalRGBColor,
        width: Double,
        context: CGContext,
        transform: PDFWorldTransform,
        alpha: CGFloat = 1
    ) {
        if let arc = segment.arc {
            drawArc(arc, color: color, width: width, context: context, transform: transform, alpha: alpha)
            return
        }

        context.saveGState()
        context.setStrokeColor(color.cgColor(alpha: alpha))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(max(transform.length(width), 0.35))
        context.move(to: transform.point(segment.from))
        context.addLine(to: transform.point(segment.to))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawArcs(
        _ arcs: [HorizontalArc],
        color: HorizontalRGBColor,
        width: Double,
        context: CGContext,
        transform: PDFWorldTransform
    ) {
        for arc in arcs {
            drawArc(arc, color: color, width: max(arc.width, width), context: context, transform: transform)
        }
    }

    private static func drawArc(
        _ arc: HorizontalArc,
        color: HorizontalRGBColor,
        width: Double,
        context: CGContext,
        transform: PDFWorldTransform,
        alpha: CGFloat = 1
    ) {
        drawPolyline(arc.polyline(), color: color, width: width, context: context, transform: transform, alpha: alpha)
    }

    private static func drawPolyline(
        _ points: [HorizontalPoint],
        color: HorizontalRGBColor,
        width: Double,
        context: CGContext,
        transform: PDFWorldTransform,
        alpha: CGFloat = 1
    ) {
        guard let first = points.first else {
            return
        }
        context.saveGState()
        context.setStrokeColor(color.cgColor(alpha: alpha))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(max(transform.length(width), 0.35))
        context.move(to: transform.point(first))
        for point in points.dropFirst() {
            context.addLine(to: transform.point(point))
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawPolygons(
        _ polygons: [HorizontalPolygon],
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        fill: Bool,
        width: Double
    ) {
        for polygon in polygons {
            drawPolygonVertices(
                polygon.renderVertices(arcPrecision: 32),
                color: color,
                context: context,
                transform: transform,
                fill: fill,
                width: width
            )
        }
    }

    private static func drawPolygonVertices(
        _ vertices: [HorizontalPoint],
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        fill: Bool,
        width: Double,
        alpha: CGFloat = 1
    ) {
        guard let first = vertices.first else {
            return
        }
        context.saveGState()
        context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor(alpha: alpha))
        context.setFillColor(color.cgColor(alpha: alpha))
        context.setLineWidth(max(transform.length(width), 0.35))
        context.move(to: transform.point(first))
        for vertex in vertices.dropFirst() {
            context.addLine(to: transform.point(vertex))
        }
        context.closePath()
        if fill {
            context.fillPath()
        } else {
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func drawCircles(
        _ circles: [HorizontalCircle],
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        width: Double
    ) {
        for circle in circles {
            drawCircle(center: circle.center, radius: circle.radius, color: color, context: context, transform: transform, width: width)
        }
    }

    private static func drawCircle(
        center: HorizontalPoint,
        radius: Double,
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        width: Double,
        fill: Bool = false,
        alpha: CGFloat = 1
    ) {
        let screenCenter = transform.point(center)
        let screenRadius = max(transform.length(radius), 0.2)
        let rect = CGRect(
            x: screenCenter.x - screenRadius,
            y: screenCenter.y - screenRadius,
            width: screenRadius * 2,
            height: screenRadius * 2
        )
        context.saveGState()
        context.setStrokeColor(color.cgColor(alpha: alpha))
        context.setFillColor(color.cgColor(alpha: alpha))
        context.setLineWidth(max(transform.length(width), 0.35))
        if fill {
            context.fillEllipse(in: rect)
        } else {
            context.strokeEllipse(in: rect)
        }
        context.restoreGState()
    }

    private static func drawDimensions(
        _ dimensions: [HorizontalDimension],
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        width: Double
    ) {
        let lineWidth = max(width, 70_000)
        for dimension in dimensions {
            let geometry = dimension.measurementGeometry
            let vector = geometry.p1Projected - geometry.p0Projected
            let length = hypot(vector.x, vector.y)
            guard length > 0 else {
                continue
            }

            let direction = vector.normalized
            let normal = geometry.normal
            let sign = dimension.labelDistance >= 0 ? 1.0 : -1.0
            let q0 = geometry.p0Projected + normal * dimension.labelDistance
            let q1 = geometry.p1Projected + normal * dimension.labelDistance
            let extensionLength = dimension.labelDistance + sign * dimension.labelSize / 2

            drawDimensionLine(
                from: dimension.p0,
                to: geometry.p0Projected + normal * extensionLength,
                color: color,
                width: lineWidth,
                context: context,
                transform: transform
            )
            drawDimensionLine(
                from: dimension.p1,
                to: geometry.p1Projected + normal * extensionLength,
                color: color,
                width: lineWidth,
                context: context,
                transform: transform
            )

            let labelWidth = HorizontalOutlineTextRenderer.textWidth(
                dimension.label,
                font: .simplex,
                size: dimension.labelSize
            )
            let center = q0 + vector * 0.5
            let lineGap = labelWidth / 2 + dimension.labelSize * 0.45
            let labelFitsBetweenArrows = labelWidth + dimension.labelSize * 2 <= length

            if !labelFitsBetweenArrows {
                drawDimensionLine(from: q0, to: q1, color: color, width: lineWidth, context: context, transform: transform)
            } else {
                drawDimensionLine(
                    from: q0,
                    to: center - direction * lineGap,
                    color: color,
                    width: lineWidth,
                    context: context,
                    transform: transform
                )
                drawDimensionLine(
                    from: center + direction * lineGap,
                    to: q1,
                    color: color,
                    width: lineWidth,
                    context: context,
                    transform: transform
                )
            }

            let arrowMul = length > dimension.labelSize * 2 ? 1.0 : -1.0
            let angle = atan2(direction.y, direction.x)
            drawDimensionArrowhead(
                at: q0,
                angle: angle,
                direction: arrowMul,
                size: dimension.labelSize,
                color: color,
                width: lineWidth,
                context: context,
                transform: transform
            )
            drawDimensionArrowhead(
                at: q1,
                angle: angle,
                direction: -arrowMul,
                size: dimension.labelSize,
                color: color,
                width: lineWidth,
                context: context,
                transform: transform
            )

            if let labelText = dimension.labelText {
                drawText(labelText, color: color, context: context, transform: transform, width: lineWidth)
            }
        }
    }

    private static func drawDimensionLine(
        from: HorizontalPoint,
        to: HorizontalPoint,
        color: HorizontalRGBColor,
        width: Double,
        context: CGContext,
        transform: PDFWorldTransform
    ) {
        drawSegment(
            HorizontalSegment(id: "dimension", from: from, to: to, width: width, layer: nil),
            color: color,
            width: width,
            context: context,
            transform: transform,
            alpha: 0.72
        )
    }

    private static func drawDimensionArrowhead(
        at origin: HorizontalPoint,
        angle: Double,
        direction: Double,
        size: Double,
        color: HorizontalRGBColor,
        width: Double,
        context: CGContext,
        transform: PDFWorldTransform
    ) {
        let first = origin + rotate(HorizontalPoint(x: direction * size, y: size / 2), angle: angle)
        let second = origin + rotate(HorizontalPoint(x: direction * size, y: -size / 2), angle: angle)
        drawDimensionLine(from: origin, to: first, color: color, width: width, context: context, transform: transform)
        drawDimensionLine(from: origin, to: second, color: color, width: width, context: context, transform: transform)
    }

    private static func appendDXFDimensions(
        _ dimensions: [HorizontalDimension],
        writer: inout HorizontalDXFWriter,
        width: Double
    ) {
        let color = HorizontalRGBColor(red: 0, green: 0, blue: 0)
        let lineWidth = max(width, 70_000)

        func appendLine(from: HorizontalPoint, to: HorizontalPoint) {
            writer.addPolyline([from, to], layer: "Dimensions", color: color, width: lineWidth)
        }

        func appendArrowhead(at origin: HorizontalPoint, angle: Double, direction: Double, size: Double) {
            let first = origin + rotate(HorizontalPoint(x: direction * size, y: size / 2), angle: angle)
            let second = origin + rotate(HorizontalPoint(x: direction * size, y: -size / 2), angle: angle)
            appendLine(from: origin, to: first)
            appendLine(from: origin, to: second)
        }

        for dimension in dimensions {
            let geometry = dimension.measurementGeometry
            let vector = geometry.p1Projected - geometry.p0Projected
            let length = hypot(vector.x, vector.y)
            guard length > 0 else {
                continue
            }

            let direction = vector.normalized
            let normal = geometry.normal
            let sign = dimension.labelDistance >= 0 ? 1.0 : -1.0
            let q0 = geometry.p0Projected + normal * dimension.labelDistance
            let q1 = geometry.p1Projected + normal * dimension.labelDistance
            let extensionLength = dimension.labelDistance + sign * dimension.labelSize / 2

            appendLine(from: dimension.p0, to: geometry.p0Projected + normal * extensionLength)
            appendLine(from: dimension.p1, to: geometry.p1Projected + normal * extensionLength)

            let labelWidth = HorizontalOutlineTextRenderer.textWidth(
                dimension.label,
                font: .simplex,
                size: dimension.labelSize
            )
            let center = q0 + vector * 0.5
            let lineGap = labelWidth / 2 + dimension.labelSize * 0.45
            let labelFitsBetweenArrows = labelWidth + dimension.labelSize * 2 <= length

            if !labelFitsBetweenArrows {
                appendLine(from: q0, to: q1)
            } else {
                appendLine(from: q0, to: center - direction * lineGap)
                appendLine(from: center + direction * lineGap, to: q1)
            }

            let arrowMul = length > dimension.labelSize * 2 ? 1.0 : -1.0
            let angle = atan2(direction.y, direction.x)
            appendArrowhead(at: q0, angle: angle, direction: arrowMul, size: dimension.labelSize)
            appendArrowhead(at: q1, angle: angle, direction: -arrowMul, size: dimension.labelSize)

            if let labelText = dimension.labelText {
                for (from, to) in HorizontalOutlineTextRenderer.outlineSegments(for: labelText) {
                    appendLine(from: from, to: to)
                }
            }
        }
    }

    private static func rotate(_ point: HorizontalPoint, angle: Double) -> HorizontalPoint {
        HorizontalPoint(
            x: point.x * cos(angle) - point.y * sin(angle),
            y: point.x * sin(angle) + point.y * cos(angle)
        )
    }

    private static func drawTexts(
        _ texts: [HorizontalText],
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        width: Double
    ) {
        for text in texts {
            drawText(text, color: color, context: context, transform: transform, width: width)
        }
    }

    private static func drawText(
        _ text: HorizontalText,
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        width: Double
    ) {
        let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
        for (from, to) in segments {
            drawSegment(
                HorizontalSegment(id: "\(text.id)/stroke", from: from, to: to, width: max(text.width, width), layer: text.layer, netID: text.netID),
                color: color,
                width: max(text.width, width),
                context: context,
                transform: transform
            )
        }
    }

    private static func drawNetLabels(
        _ labels: [HorizontalSchematicNetLabel],
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        width: Double
    ) {
        for label in labels {
            drawFlagLabel(
                id: label.id,
                text: label.text,
                position: label.position,
                size: label.size,
                orientation: label.orientation,
                netID: label.netID,
                color: color,
                context: context,
                transform: transform,
                width: width
            )
        }
    }

    private static func drawBusLabels(
        _ labels: [HorizontalBusLabel],
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        width: Double
    ) {
        for label in labels {
            drawFlagLabel(
                id: label.id,
                text: label.text,
                position: label.position,
                size: label.size,
                orientation: label.orientation,
                netID: label.netID,
                color: color,
                context: context,
                transform: transform,
                width: width
            )
        }
    }

    private static func drawFlagLabel(
        id: String,
        text labelText: String,
        position: HorizontalPoint,
        size: Double,
        orientation: String,
        netID: String?,
        color: HorizontalRGBColor,
        context: CGContext,
        transform: PDFWorldTransform,
        width: Double
    ) {
        let text = flagLabelText(
            id: id,
            text: labelText,
            position: position,
            size: size,
            orientation: orientation,
            netID: netID,
            width: width
        )
        let (min, max) = labelBounds(for: text)
        let points = flagPoints(position: position, min: min, max: max, orientation: orientation)
        drawPolygonVertices(points, color: color, context: context, transform: transform, fill: true, width: width, alpha: 0.08)
        drawPolyline(points, color: color, width: width, context: context, transform: transform)
        drawText(text, color: color, context: context, transform: transform, width: width)
    }

    private static func flagLabelText(
        id: String,
        text labelText: String,
        position: HorizontalPoint,
        size: Double,
        orientation: String,
        netID: String?,
        width: Double
    ) -> HorizontalText {
        HorizontalText(
            id: "\(id)/label-text",
            text: labelText,
            position: position + labelTextShift(size: size, orientation: orientation),
            size: size,
            layer: nil,
            netID: netID,
            angle: textAngle(forOrientation: orientation),
            width: width,
            origin: .center,
            font: .simplex
        )
    }

    private static func labelBounds(for text: HorizontalText) -> (HorizontalPoint, HorizontalPoint) {
        let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
        let points = [text.position] + segments.flatMap { [$0.0, $0.1] }
        let bounds = HorizontalRect(points: points)
        let enlarge = text.size / 4
        return (
            HorizontalPoint(x: bounds.minX - enlarge, y: bounds.minY - enlarge),
            HorizontalPoint(x: bounds.maxX + enlarge, y: bounds.maxY + enlarge)
        )
    }

    private static func labelBoundsPoints(
        id: String,
        text labelText: String,
        position: HorizontalPoint,
        size: Double,
        orientation: String
    ) -> [HorizontalPoint] {
        let text = flagLabelText(
            id: id,
            text: labelText,
            position: position,
            size: size,
            orientation: orientation,
            netID: nil,
            width: 0
        )
        let (min, max) = labelBounds(for: text)
        return flagBoundsPoints(position: position, min: min, max: max)
    }

    private static func flagBoundsPoints(position: HorizontalPoint, min: HorizontalPoint, max: HorizontalPoint) -> [HorizontalPoint] {
        [
            position,
            min,
            max,
            HorizontalPoint(x: min.x, y: max.y),
            HorizontalPoint(x: max.x, y: min.y)
        ]
    }

    private static func flagPoints(
        position: HorizontalPoint,
        min: HorizontalPoint,
        max: HorizontalPoint,
        orientation: String
    ) -> [HorizontalPoint] {
        let topLeft = HorizontalPoint(x: min.x, y: max.y)
        let bottomRight = HorizontalPoint(x: max.x, y: min.y)
        switch orientation {
        case "left":
            return [min, topLeft, max, position, bottomRight, min]
        case "up":
            return [position, min, topLeft, max, bottomRight, position]
        case "down":
            return [position, max, bottomRight, min, topLeft, position]
        default:
            return [max, bottomRight, min, position, topLeft, max]
        }
    }

    private static func circleBoundsPoints(center: HorizontalPoint, radius: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: center.x - radius, y: center.y - radius),
            HorizontalPoint(x: center.x + radius, y: center.y + radius)
        ]
    }

    private static func labelTextShift(size: Double, orientation: String) -> HorizontalPoint {
        switch orientation {
        case "left":
            return HorizontalPoint(x: -size, y: 0)
        case "up":
            return HorizontalPoint(x: 0, y: size)
        case "down":
            return HorizontalPoint(x: 0, y: -size)
        default:
            return HorizontalPoint(x: size, y: 0)
        }
    }

    private static func textAngle(forOrientation orientation: String) -> Int {
        switch orientation {
        case "up":
            return 16_384
        case "left":
            return 32_768
        case "down":
            return 49_152
        default:
            return 0
        }
    }

    private static func gerberObjects(
        for board: HorizontalBoard,
        layer targetLayer: Int,
        outlineWidthMM: Double,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil
    ) -> [GerberPrimitive] {
        let defaultWidth = max(outlineWidthMM * 1_000_000, 10_000)
        var objects = [GerberPrimitive]()

        // Silkscreen clipped to the solder mask goes out as regions; every
        // object the clipping left alone goes out exactly as before.
        let clippedSilk = silkscreenClipping.flatMap { clipping in
            HorizontalSilkscreenClipper.clippedLayer(targetLayer, board: board, clipping: clipping)
        }
        func appendClippedSilk(_ id: String) -> Bool {
            guard let clipped = clippedSilk?.object(id) else {
                return false
            }
            for fragment in clipped.fragments {
                let contour = HorizontalSilkscreenClipper.bridgedContour(fragment)
                if contour.count >= 3 {
                    objects.append(.region(contour))
                }
            }
            return true
        }

        func appendText(_ text: HorizontalText) {
            guard text.layer == targetLayer else {
                return
            }
            if appendClippedSilk(text.id) {
                return
            }
            let width = max(text.width, defaultWidth)
            for (from, to) in HorizontalOutlineTextRenderer.outlineSegments(for: text) {
                objects.append(.line(from, to, width))
            }
        }

        for plane in board.planes where plane.layer == targetLayer {
            for fragment in plane.renderFragments {
                for path in fragment.paths where path.count >= 3 {
                    objects.append(.region(path))
                }
            }
        }
        for polygon in board.polygons + board.packagePolygons where polygon.layer == targetLayer {
            if appendClippedSilk(polygon.id) { continue }
            let vertices = polygon.renderVertices(arcPrecision: 32)
            guard vertices.count >= 3 else { continue }
            objects.append(.region(vertices))
        }
        for pad in horizonPadOutlineFragments(board.packagePads) where pad.layer == targetLayer {
            for path in pad.paths where path.count >= 3 {
                objects.append(.region(path))
            }
        }
        // Via annular rings. A via's padstack copper is a circle of its
        // diameter on every copper layer of its span (Horizon's via padstacks
        // put the same `via_diameter` circle on top, inner and bottom), so the
        // ring goes on exactly the layers the canvas renders it on.
        for via in board.vias where via.copperLayers.contains(targetLayer) {
            let ring = via.ringOutline()
            guard ring.count >= 3 else { continue }
            objects.append(.region(ring))
        }
        // Via solder-mask openings: the padstack's expanded mask circle, on
        // the mask files exactly as the canvas shows it. maskOutline is empty
        // for every non-mask target layer and for tented vias.
        for via in board.vias {
            let opening = via.maskOutline(on: targetLayer)
            guard opening.count >= 3 else { continue }
            objects.append(.region(opening))
        }
        // Keepouts are design-rule regions, not copper or artwork: Horizon's
        // Gerber export skips them, so they never reach fabrication output.
        for segment in board.tracks + board.netTies + board.lines + board.packageLines where segment.layer == targetLayer {
            if appendClippedSilk(segment.id) { continue }
            if let arc = segment.arc {
                objects.append(.polyline(arc.polyline(), max(segment.width, defaultWidth)))
            } else {
                objects.append(.line(segment.from, segment.to, max(segment.width, defaultWidth)))
            }
        }
        for arc in board.arcs where arc.layer == targetLayer {
            if appendClippedSilk(arc.id) { continue }
            objects.append(.polyline(arc.polyline(), max(arc.width, defaultWidth)))
        }
        for arc in board.packageArcs where arc.layer == targetLayer {
            if appendClippedSilk(arc.id) { continue }
            objects.append(.polyline(arc.polyline(), max(arc.width, defaultWidth)))
        }
        for decal in board.decals {
            for polygon in decal.polygons where polygon.layer == targetLayer {
                if appendClippedSilk(polygon.id) { continue }
                let vertices = polygon.renderVertices(arcPrecision: 32)
                guard vertices.count >= 3 else { continue }
                objects.append(.region(vertices))
            }
            for line in decal.lines where line.layer == targetLayer {
                if appendClippedSilk(line.id) { continue }
                objects.append(.line(line.from, line.to, max(line.width, defaultWidth)))
            }
            for arc in decal.arcs where arc.layer == targetLayer {
                if appendClippedSilk(arc.id) { continue }
                objects.append(.polyline(arc.polyline(), max(arc.width, defaultWidth)))
            }
            decal.texts.forEach(appendText)
        }
        (board.texts + board.packageTexts).forEach(appendText)
        return objects
    }

    private static func writeGerberLayer(_ objects: [GerberPrimitive], layerName: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var widths = Set<Double>()
        for object in objects {
            switch object {
            case .line(_, _, let width), .polyline(_, let width):
                widths.insert(max(width, 10_000))
            case .region:
                break
            }
        }
        let sortedWidths = widths.sorted()
        var apertureCodes = [Double: Int]()
        for (index, width) in sortedWidths.enumerated() {
            apertureCodes[width] = 10 + index
        }

        var lines = [
            "G04 Horizontal \(layerName)*",
            "%FSLAX46Y46*%",
            "%MOMM*%",
            "%LPD*%"
        ]
        for width in sortedWidths {
            let code = apertureCodes[width] ?? 10
            lines.append("%ADD\(code)C,\(String(format: "%.6f", width / 1_000_000))*%")
        }
        lines.append("G01*")

        func coordinate(_ point: HorizontalPoint) -> String {
            "X\(Int64(point.x.rounded()))Y\(Int64(point.y.rounded()))"
        }

        func selectAperture(_ width: Double) {
            let normalizedWidth = max(width, 10_000)
            let code = apertureCodes[normalizedWidth] ?? apertureCodes[sortedWidths.min() ?? normalizedWidth] ?? 10
            lines.append("D\(code)*")
        }

        for object in objects {
            switch object {
            case .line(let from, let to, let width):
                selectAperture(width)
                lines.append("\(coordinate(from))D02*")
                lines.append("\(coordinate(to))D01*")
            case .polyline(let points, let width):
                guard let first = points.first else {
                    continue
                }
                selectAperture(width)
                lines.append("\(coordinate(first))D02*")
                for point in points.dropFirst() {
                    lines.append("\(coordinate(point))D01*")
                }
            case .region(let points):
                guard let first = points.first else {
                    continue
                }
                lines.append("G36*")
                lines.append("\(coordinate(first))D02*")
                for point in points.dropFirst() {
                    lines.append("\(coordinate(point))D01*")
                }
                lines.append("\(coordinate(first))D01*")
                lines.append("G37*")
            }
        }
        lines.append("M02*")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: [.atomic])
    }

    private static func writeDrillFiles(
        board: HorizontalBoard,
        settings: HorizontalGerberExportSettings,
        prefix: String,
        to directoryURL: URL
    ) throws -> [URL] {
        let hits = (board.holes + board.viaHoles + board.packageHoles).map { DrillHit(position: $0.position, diameter: $0.diameter, plated: $0.plated) }
        guard !hits.isEmpty else {
            return []
        }

        func write(_ hits: [DrillHit], filename: String) throws -> URL? {
            guard !hits.isEmpty else {
                return nil
            }
            let url = directoryURL.appendingPathComponent(filename)
            try writeExcellon(hits, to: url)
            return url
        }

        switch settings.drillMode {
        case .merged:
            return [try write(hits, filename: "\(prefix)\(settings.drillPTHSuffix)")].compactMap { $0 }
        case .individual:
            return try [
                write(hits.filter(\.plated), filename: "\(prefix)\(settings.drillPTHSuffix)"),
                write(hits.filter { !$0.plated }, filename: "\(prefix)\(settings.drillNPTHSuffix)")
            ].compactMap { $0 }
        }
    }

    private static func writeExcellon(_ hits: [DrillHit], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sortedDiameters = Array(Set(hits.map(\.diameter))).sorted()
        let toolCodes = Dictionary(uniqueKeysWithValues: sortedDiameters.enumerated().map { index, diameter in
            (diameter, index + 1)
        })
        var lines = [
            "M48",
            "METRIC,TZ"
        ]
        for diameter in sortedDiameters {
            let code = toolCodes[diameter] ?? 1
            lines.append("T\(String(format: "%02d", code))C\(String(format: "%.4f", diameter / 1_000_000))")
        }
        lines.append("%")
        for diameter in sortedDiameters {
            let code = toolCodes[diameter] ?? 1
            lines.append("T\(String(format: "%02d", code))")
            for hit in hits where hit.diameter == diameter {
                lines.append(String(format: "X%.4fY%.4f", hit.position.x / 1_000_000, hit.position.y / 1_000_000))
            }
        }
        lines.append("M30")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: [.atomic])
    }

    private static func writeODBJob(
        project: HorizontalProject,
        board: HorizontalBoard,
        jobName: String,
        to jobURL: URL,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil
    ) throws {
        try FileManager.default.createDirectory(at: jobURL, withIntermediateDirectories: true)
        let stepName = odbLegalEntityName(project.displayTitle.isEmpty ? "pcb" : project.displayTitle)
        let layerIDs = boardLayerIDs(for: board)
        let layers = layerIDs.compactMap { layer -> ODBLayer? in
            let objects = gerberObjects(for: board, layer: layer, outlineWidthMM: 0.01, silkscreenClipping: silkscreenClipping)
            guard !objects.isEmpty else {
                return nil
            }
            return ODBLayer(id: layer, name: odbLayerName(for: layer, board: board), type: odbLayerType(for: layer), context: odbLayerContext(for: layer), objects: objects)
        }

        try writeODBMatrix(stepName: stepName, layers: layers, to: jobURL.appendingPathComponent("matrix/matrix"))
        try writeODBInfo(project: project, jobName: jobName, to: jobURL.appendingPathComponent("misc/info"))
        try writeODBStepHeader(to: jobURL.appendingPathComponent("steps/\(stepName)/stephdr"))
        for layer in layers {
            let url = jobURL.appendingPathComponent("steps/\(stepName)/layers/\(layer.name)/features")
            try writeODBFeatures(layer.objects, to: url)
        }
        try writeODBProfile(board: board, to: jobURL.appendingPathComponent("steps/\(stepName)/profile"))
        try writeODBEDAData(board: board, to: jobURL.appendingPathComponent("steps/\(stepName)/eda/data"))
    }

    private static func writeODBMatrix(stepName: String, layers: [ODBLayer], to url: URL) throws {
        var row = 1
        var lines = [String]()
        lines += odbArray("STEP", [
            ("COL", "1"),
            ("NAME", stepName)
        ])
        for layer in layers {
            var fields = [
                ("ROW", "\(row)"),
                ("CONTEXT", layer.context),
                ("TYPE", layer.type),
                ("NAME", layer.name),
                ("POLARITY", "POSITIVE")
            ]
            if HorizontalBoardLayers.isCopper(layer.id), layer.id != HorizontalBoardLayers.topCopper {
                fields.append(("START_NAME", odbLayerName(for: HorizontalBoardLayers.bottomCopper, board: nil)))
                fields.append(("END_NAME", odbLayerName(for: HorizontalBoardLayers.topCopper, board: nil)))
            }
            lines += odbArray("LAYER", fields)
            row += 1
        }
        try writeODBText(lines.joined(), to: url)
    }

    private static func writeODBInfo(project: HorizontalProject, jobName: String, to url: URL) throws {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd.HHmmss"
        let stamp = formatter.string(from: now)
        let text = [
            "UNITS=MM",
            "ODB_VERSION_MAJOR=8",
            "ODB_VERSION_MINOR=1",
            "CREATION_DATE=\(stamp)",
            "SAVE_DATE=\(stamp)",
            "ODB_SOURCE=Horizontal",
            "JOB_NAME=\(jobName)",
            "SAVE_APP=Horizontal",
            "PROJECT_NAME=\(project.displayTitle)"
        ].joined(separator: "\r\n") + "\r\n"
        try writeODBText(text, to: url)
    }

    private static func writeODBStepHeader(to url: URL) throws {
        let text = [
            "UNITS=MM",
            "X_DATUM=0",
            "Y_DATUM=0",
            "X_ORIGIN=0",
            "Y_ORIGIN=0",
            "AFFECTING_BOM=0",
            "AFFECTING_BOM_CHANGED=0"
        ].joined(separator: "\r\n") + "\r\n"
        try writeODBText(text, to: url)
    }

    private static func writeODBFeatures(_ objects: [GerberPrimitive], to url: URL) throws {
        var widths = Set<Double>()
        for object in objects {
            switch object {
            case .line(_, _, let width), .polyline(_, let width):
                widths.insert(max(width, 10_000))
            case .region:
                break
            }
        }
        let sortedWidths = widths.sorted()
        let symbolIDs = Dictionary(uniqueKeysWithValues: sortedWidths.enumerated().map { index, width in
            (width, index)
        })
        var lines = [
            "UNITS=MM",
            "#Symbols"
        ]
        for width in sortedWidths {
            let symbol = symbolIDs[width] ?? 0
            lines.append("$\(symbol) r\(String(format: "%.3f", width / 1_000)) M")
        }
        for object in objects {
            switch object {
            case .line(let from, let to, let width):
                let symbol = symbolIDs[max(width, 10_000)] ?? 0
                lines.append("L \(odbPoint(from)) \(odbPoint(to)) \(symbol) P 0")
            case .polyline(let points, let width):
                let symbol = symbolIDs[max(width, 10_000)] ?? 0
                for pair in zip(points, points.dropFirst()) {
                    lines.append("L \(odbPoint(pair.0)) \(odbPoint(pair.1)) \(symbol) P 0")
                }
            case .region(let points):
                guard let last = points.last else {
                    continue
                }
                lines.append("S P 0")
                lines.append("OB \(odbPoint(last)) H")
                for point in points {
                    lines.append("OS \(odbPoint(point))")
                }
                lines.append("OE")
                lines.append("SE")
            }
        }
        try writeODBText(lines.joined(separator: "\r\n") + "\r\n", to: url)
    }

    private static func writeODBProfile(board: HorizontalBoard, to url: URL) throws {
        let contours = boardProfileContours(for: board)
        var lines = [String]()
        for (index, contour) in contours.enumerated() {
            guard let last = contour.last else {
                continue
            }
            lines.append("OB \(odbPoint(last)) \(index == 0 ? "H" : "I")")
            for point in contour {
                lines.append("OS \(odbPoint(point))")
            }
            lines.append("OE")
        }
        try writeODBText(lines.joined(separator: "\r\n") + "\r\n", to: url)
    }

    private static func writeODBEDAData(board: HorizontalBoard, to url: URL) throws {
        var lines = [
            "# Native Horizontal ODB++ first-pass EDA data",
            "# Nets"
        ]
        for net in board.netDetails.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            lines.append("NET \(odbLegalName(net.name.isEmpty ? net.id : net.name))")
        }
        try writeODBText(lines.joined(separator: "\r\n") + "\r\n", to: url)
    }

    private static func writeODBText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    private static func odbArray(_ name: String, _ fields: [(String, String)]) -> [String] {
        var lines = ["\(name) {\r\n"]
        for (key, value) in fields {
            lines.append("    \(key)=\(value)\r\n")
        }
        lines.append("}\r\n\r\n")
        return lines
    }

    private static func boardProfileContours(for board: HorizontalBoard) -> [[HorizontalPoint]] {
        let outlinePolygons = (board.polygons + board.packagePolygons)
            .filter { $0.layer == HorizontalBoardLayers.outline }
            .map { $0.renderVertices(arcPrecision: 32) }
            .filter { $0.count >= 3 }
        if !outlinePolygons.isEmpty {
            return outlinePolygons
        }

        let bounds = board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds
        guard !bounds.isEmpty else {
            return []
        }
        return [[
            HorizontalPoint(x: bounds.minX, y: bounds.minY),
            HorizontalPoint(x: bounds.maxX, y: bounds.minY),
            HorizontalPoint(x: bounds.maxX, y: bounds.maxY),
            HorizontalPoint(x: bounds.minX, y: bounds.maxY)
        ]]
    }

    private static func boardLayerIDs(for board: HorizontalBoard) -> [Int] {
        let fixedLayers = [
            HorizontalBoardLayers.outline,
            HorizontalBoardLayers.topPaste,
            HorizontalBoardLayers.topSilkscreen,
            HorizontalBoardLayers.topMask,
            HorizontalBoardLayers.topCopper,
            HorizontalBoardLayers.bottomCopper,
            HorizontalBoardLayers.bottomMask,
            HorizontalBoardLayers.bottomSilkscreen,
            HorizontalBoardLayers.bottomPaste
        ]
        let layers = Set(
            fixedLayers
                + board.stackupLayers.map(\.layer)
                + board.userLayers.map(\.id)
                + board.polygons.compactMap(\.layer)
                + board.packagePolygons.compactMap(\.layer)
                + board.packagePads.compactMap(\.layer)
                + board.tracks.compactMap(\.layer)
                + board.netTies.compactMap(\.layer)
                + board.lines.compactMap(\.layer)
                + board.packageLines.compactMap(\.layer)
                + board.arcs.compactMap(\.layer)
                + board.packageArcs.compactMap(\.layer)
                + board.decals.flatMap { decal in
                    decal.polygons.compactMap(\.layer)
                        + decal.lines.compactMap(\.layer)
                        + decal.arcs.compactMap(\.layer)
                        + decal.texts.compactMap(\.layer)
                }
                + board.texts.compactMap(\.layer)
                + board.packageTexts.compactMap(\.layer)
        )
        return HorizontalBoardLayers.all.filter { layers.contains($0) }
    }

    private static func odbLayerName(for layer: Int, board: HorizontalBoard?) -> String {
        switch layer {
        case HorizontalBoardLayers.topCopper:
            return "signal_top"
        case HorizontalBoardLayers.bottomCopper:
            return "signal_bottom"
        case HorizontalBoardLayers.in8Copper...HorizontalBoardLayers.in1Copper:
            return "signal_inner_\(-layer)"
        case HorizontalBoardLayers.topSilkscreen:
            return "silkscreen_top"
        case HorizontalBoardLayers.bottomSilkscreen:
            return "silkscreen_bottom"
        case HorizontalBoardLayers.topMask:
            return "mask_top"
        case HorizontalBoardLayers.bottomMask:
            return "mask_bottom"
        case HorizontalBoardLayers.topPaste:
            return "paste_top"
        case HorizontalBoardLayers.bottomPaste:
            return "paste_bottom"
        case HorizontalBoardLayers.topAssembly:
            return "assembly_top"
        case HorizontalBoardLayers.bottomAssembly:
            return "assembly_bottom"
        default:
            if HorizontalBoardLayers.isUser(layer), let board, let userLayer = board.userLayers.first(where: { $0.id == layer }) {
                return odbLegalEntityName(userLayer.name)
            }
            return "layer_id_\(layer)"
        }
    }

    private static func odbLayerType(for layer: Int) -> String {
        switch layer {
        case HorizontalBoardLayers.topPaste, HorizontalBoardLayers.bottomPaste:
            return "SOLDER_PASTE"
        case HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen:
            return "SILK_SCREEN"
        case HorizontalBoardLayers.topMask, HorizontalBoardLayers.bottomMask:
            return "SOLDER_MASK"
        default:
            if HorizontalBoardLayers.isCopper(layer) {
                return "SIGNAL"
            }
            return "DOCUMENT"
        }
    }

    private static func odbLayerContext(for layer: Int) -> String {
        HorizontalBoardLayers.isUser(layer) || layer == HorizontalBoardLayers.topAssembly || layer == HorizontalBoardLayers.bottomAssembly ? "MISC" : "BOARD"
    }

    private static func odbPoint(_ point: HorizontalPoint) -> String {
        String(format: "%.6f %.6f", point.x / 1_000_000, point.y / 1_000_000)
    }

    private static func odbLegalName(_ value: String) -> String {
        let mapped = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "+" {
                return Character(scalar)
            }
            return "_"
        }
        let output = String(mapped)
        return output.isEmpty ? "_" : output
    }

    private static func odbLegalEntityName(_ value: String) -> String {
        let mapped = value.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "_" || scalar == "-" || scalar == "+" {
                return Character(scalar)
            }
            return "_"
        }
        let output = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return output.isEmpty ? "pcb" : output
    }
}

#if canImport(AppKit)
public enum HorizontalBoardThumbnailRenderer {
    public static func image(forProjectAt url: URL, fitting requestedSize: CGSize) throws -> NSImage {
        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var result: Result<NSImage, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                let project = try HorizontalProject.load(from: coordinatedURL)
                return try HorizontalExportBackend.boardThumbnailImage(
                    project: project,
                    fitting: requestedSize
                )
            }
        }

        if let result {
            return try result.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw previewError("Quick Look could not coordinate access to \(url.lastPathComponent).")
    }

    private static func previewError(_ message: String) -> NSError {
        NSError(
            domain: "com.twarge.horizontal.QuickLook",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

public enum HorizontalSchematicPreviewRenderer {
    public static func pdfURL(forProjectAt url: URL) throws -> URL {
        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var result: Result<URL, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                let project = try HorizontalProject.load(from: coordinatedURL)
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HorizontalQuickLook-\(UUID().uuidString)")
                    .appendingPathExtension("pdf")
                try HorizontalExportBackend.writeSchematicPreviewPDF(
                    project: project,
                    to: outputURL
                )
                return outputURL
            }
        }

        if let result {
            return try result.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw previewError("Quick Look could not coordinate access to \(url.lastPathComponent).")
    }

    public static func image(forProjectAt url: URL, fitting requestedSize: CGSize) throws -> NSImage {
        let pdfURL = try pdfURL(forProjectAt: url)
        return try image(forPDFAt: pdfURL, fitting: requestedSize)
    }

    private static func image(forPDFAt url: URL, fitting requestedSize: CGSize) throws -> NSImage {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else {
            throw previewError("Could not render schematic preview.")
        }

        let pageBounds = page.getBoxRect(.mediaBox)
        let size = CGSize(
            width: max(requestedSize.width.rounded(.up), 96),
            height: max(requestedSize.height.rounded(.up), 96)
        )
        let scale = min(size.width / max(pageBounds.width, 1), size.height / max(pageBounds.height, 1))
        let drawSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        let drawOrigin = CGPoint(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2
        )

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        CGRect(origin: .zero, size: size).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: drawOrigin.x, y: drawOrigin.y)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
        image.unlockFocus()
        return image
    }

    private static func previewError(_ message: String) -> NSError {
        NSError(
            domain: "com.twarge.horizontal.QuickLook",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

extension HorizontalExportBackend {
    fileprivate static func boardThumbnailImage(project: HorizontalProject, fitting requestedSize: CGSize) throws -> NSImage {
        guard let board = project.board else {
            throw HorizontalExportError("No board loaded.")
        }

        let size = CGSize(
            width: max(requestedSize.width.rounded(.up), 96),
            height: max(requestedSize.height.rounded(.up), 96)
        )
        let palette = HorizontalCanvasPalette.defaultPalette(kind: .board, mode: .dark)
        let layerSettings = boardThumbnailLayerSettings(palette: palette)
        let image = NSImage(size: size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            let bounds = (board.physicalBounds.isEmpty ? board.bounds : board.physicalBounds).padded(0.08)
            let transform = PDFWorldTransform(bounds: bounds, pageSize: size, margin: 8)
            drawBoardThumbnail(
                board,
                context: context,
                transform: transform,
                palette: palette,
                layerSettings: layerSettings,
                minimumLineWidthMM: 0.08
            )
        }
        image.unlockFocus()
        return image
    }

    private static func boardThumbnailLayerSettings(palette: HorizontalCanvasPalette) -> [Int: HorizontalExportLayerSetting] {
        let layers: [(Int, HorizontalPDFLayerMode)] = [
            (HorizontalBoardLayers.outline, .outline),
            (HorizontalBoardLayers.topCopper, .fill),
            (HorizontalBoardLayers.topSilkscreen, .fill)
        ]
        return Dictionary(uniqueKeysWithValues: layers.map { layer, mode in
            (
                layer,
                HorizontalExportLayerSetting(
                    layer: layer,
                    name: HorizontalBoardLayers.name(for: layer),
                    enabled: true,
                    filename: "",
                    mode: mode,
                    color: rgbColor(from: palette.layerColor(for: layer))
                )
            )
        })
    }

    private static func drawBoardThumbnail(
        _ board: HorizontalBoard,
        context: CGContext,
        transform: PDFWorldTransform,
        palette: HorizontalCanvasPalette,
        layerSettings: [Int: HorizontalExportLayerSetting],
        minimumLineWidthMM: Double
    ) {
        context.setFillColor(rgbColor(from: palette.background).cgColor(alpha: 1))
        context.fill(CGRect(origin: .zero, size: transform.pageSize))
        let defaultWidth = max(minimumLineWidthMM * 1_000_000, 80_000)

        func setting(for layer: Int?) -> HorizontalExportLayerSetting? {
            guard let layer, let setting = layerSettings[layer], setting.enabled else {
                return nil
            }
            return setting
        }

        for plane in board.planes {
            guard let setting = setting(for: plane.layer) else { continue }
            for fragment in plane.renderFragments {
                for path in fragment.paths {
                    drawPolygonVertices(path, color: setting.color, context: context, transform: transform, fill: true, width: defaultWidth, alpha: 0.4)
                }
            }
        }
        for polygon in board.polygons + board.packagePolygons {
            guard let setting = setting(for: polygon.layer) else { continue }
            drawPolygonVertices(polygon.renderVertices(arcPrecision: 32), color: setting.color, context: context, transform: transform, fill: setting.mode == .fill, width: defaultWidth)
        }
        for pad in horizonPadOutlineFragments(board.packagePads) {
            guard let setting = setting(for: pad.layer) else { continue }
            for path in pad.paths where path.count >= 3 {
                drawPolygonVertices(path, color: setting.color, context: context, transform: transform, fill: setting.mode == .fill, width: defaultWidth)
            }
        }
        for segment in board.tracks + board.netTies + board.lines + board.packageLines {
            guard let setting = setting(for: segment.layer) else { continue }
            drawSegment(segment, color: setting.color, width: max(segment.width, defaultWidth), context: context, transform: transform)
        }
        for arc in board.arcs + board.packageArcs {
            guard let setting = setting(for: arc.layer) else { continue }
            drawArc(arc, color: setting.color, width: max(arc.width, defaultWidth), context: context, transform: transform)
        }
        for decal in board.decals {
            for polygon in decal.polygons {
                guard let setting = setting(for: polygon.layer) else { continue }
                drawPolygonVertices(polygon.renderVertices(arcPrecision: 32), color: setting.color, context: context, transform: transform, fill: setting.mode == .fill, width: defaultWidth)
            }
            for line in decal.lines {
                guard let setting = setting(for: line.layer) else { continue }
                drawSegment(line, color: setting.color, width: max(line.width, defaultWidth), context: context, transform: transform)
            }
            for arc in decal.arcs {
                guard let setting = setting(for: arc.layer) else { continue }
                drawArc(arc, color: setting.color, width: max(arc.width, defaultWidth), context: context, transform: transform)
            }
            for text in decal.texts {
                guard let setting = setting(for: text.layer) else { continue }
                drawText(text, color: setting.color, context: context, transform: transform, width: defaultWidth)
            }
        }
        for text in board.texts + board.packageTexts {
            guard let setting = setting(for: text.layer) else { continue }
            drawText(text, color: setting.color, context: context, transform: transform, width: defaultWidth)
        }
        for hole in board.holes + board.viaHoles + board.packageHoles {
            drawCircle(
                center: hole.position,
                radius: hole.diameter / 2,
                color: HorizontalRGBColor(red: 0.95, green: 0.95, blue: 0.95),
                context: context,
                transform: transform,
                width: defaultWidth
            )
        }
    }

    fileprivate static func writeSchematicPreviewPDF(project: HorizontalProject, to url: URL) throws {
        try exportSchematicPDF(
            project: project,
            settings: HorizontalSchematicPDFExportSettings(filename: url.lastPathComponent),
            palette: HorizontalCanvasPalette.defaultPalette(kind: .schematic, mode: .light),
            to: url
        )
    }
}
#endif

private struct PDFWorldTransform {
    var bounds: HorizontalRect
    var pageSize: CGSize
    var margin: CGFloat = 36
    var scale: CGFloat
    var origin: CGPoint

    init(bounds: HorizontalRect, pageSize: CGSize, margin: CGFloat = 36) {
        self.bounds = bounds.isEmpty ? HorizontalRect(center: .zero, size: 100_000_000) : bounds
        self.pageSize = pageSize
        self.margin = margin
        let availableWidth = max(pageSize.width - margin * 2, 1)
        let availableHeight = max(pageSize.height - margin * 2, 1)
        scale = min(availableWidth / CGFloat(max(self.bounds.width, 1)), availableHeight / CGFloat(max(self.bounds.height, 1)))
        let contentWidth = CGFloat(max(self.bounds.width, 1)) * scale
        let contentHeight = CGFloat(max(self.bounds.height, 1)) * scale
        origin = CGPoint(
            x: (pageSize.width - contentWidth) / 2,
            y: (pageSize.height - contentHeight) / 2
        )
    }

    func point(_ point: HorizontalPoint) -> CGPoint {
        CGPoint(
            x: origin.x + CGFloat(point.x - bounds.minX) * scale,
            y: origin.y + CGFloat(point.y - bounds.minY) * scale
        )
    }

    func length(_ value: Double) -> CGFloat {
        CGFloat(value) * scale
    }
}

private enum GerberPrimitive {
    case line(HorizontalPoint, HorizontalPoint, Double)
    case polyline([HorizontalPoint], Double)
    case region([HorizontalPoint])
}

private struct HorizontalDXFLayer {
    var name: String
    var color: HorizontalRGBColor
}

private struct HorizontalDXFWriter {
    private var layers = [String: HorizontalDXFLayer]()
    private var layerOrder = [String]()
    private var entities = [String]()

    mutating func addLayer(_ name: String, color: HorizontalRGBColor) {
        let normalizedName = sanitizedLayerName(name)
        guard layers[normalizedName] == nil else {
            return
        }
        layers[normalizedName] = HorizontalDXFLayer(name: normalizedName, color: color)
        layerOrder.append(normalizedName)
    }

    mutating func addPolyline(
        _ points: [HorizontalPoint],
        layer: String,
        color: HorizontalRGBColor,
        width: Double,
        closed: Bool = false
    ) {
        let normalizedPoints = dxfPolylinePoints(points, closed: closed)
        guard normalizedPoints.count >= 2 else {
            return
        }

        let layerName = sanitizedLayerName(layer)
        addLayer(layerName, color: color)
        var entity = [String]()
        appendPair(0, "LWPOLYLINE", to: &entity)
        appendPair(100, "AcDbEntity", to: &entity)
        appendPair(8, layerName, to: &entity)
        appendPair(420, trueColor(color), to: &entity)
        appendPair(100, "AcDbPolyline", to: &entity)
        appendPair(90, normalizedPoints.count, to: &entity)
        appendPair(70, closed ? 1 : 0, to: &entity)
        appendPair(43, mm(width), to: &entity)
        for point in normalizedPoints {
            appendPair(10, mm(point.x), to: &entity)
            appendPair(20, mm(point.y), to: &entity)
        }
        entities.append(entity.joined())
    }

    mutating func addGerberApertureStroke(
        _ points: [HorizontalPoint],
        layer: String,
        color: HorizontalRGBColor,
        width: Double,
        fill: Bool,
        outlineWidth: Double
    ) {
        let strokePoints = normalizedPolylinePoints(points, closed: false)
        guard strokePoints.count >= 2 else {
            return
        }

        for pair in zip(strokePoints, strokePoints.dropFirst()) {
            guard let capsule = gerberApertureCapsule(from: pair.0, to: pair.1, width: width) else {
                continue
            }
            addClosedPolygon(
                capsule,
                layer: layer,
                color: color,
                fill: fill,
                outlineWidth: outlineWidth
            )
        }
    }

    mutating func addClosedPolygon(
        _ points: [HorizontalPoint],
        layer: String,
        color: HorizontalRGBColor,
        fill: Bool,
        outlineWidth: Double
    ) {
        let polygonPoints = normalizedPolylinePoints(points, closed: true)
        guard polygonPoints.count >= 3 else {
            return
        }
        if fill {
            addSolidHatch(polygonPoints, layer: layer, color: color)
        }
        addPolyline(
            polygonPoints,
            layer: layer,
            color: color,
            width: outlineWidth,
            closed: true
        )
    }

    mutating func addCircle(
        center: HorizontalPoint,
        radius: Double,
        layer: String,
        color: HorizontalRGBColor,
        width: Double
    ) {
        guard radius > 0 else {
            return
        }

        let layerName = sanitizedLayerName(layer)
        addLayer(layerName, color: color)
        var entity = [String]()
        appendPair(0, "CIRCLE", to: &entity)
        appendPair(100, "AcDbEntity", to: &entity)
        appendPair(8, layerName, to: &entity)
        appendPair(420, trueColor(color), to: &entity)
        appendPair(370, lineWeight(width), to: &entity)
        appendPair(100, "AcDbCircle", to: &entity)
        appendPair(10, mm(center.x), to: &entity)
        appendPair(20, mm(center.y), to: &entity)
        appendPair(30, "0.0", to: &entity)
        appendPair(40, mm(radius), to: &entity)
        entities.append(entity.joined())
    }

    mutating func addArc(
        _ arc: HorizontalArc,
        layer: String,
        color: HorizontalRGBColor,
        width: Double
    ) {
        let center = arc.projectedCenter
        let radius = arc.radius
        guard radius > 0 else {
            return
        }

        let fromAngle = degrees(atan2(arc.from.y - center.y, arc.from.x - center.x))
        let toAngle = degrees(atan2(arc.to.y - center.y, arc.to.x - center.x))
        let layerName = sanitizedLayerName(layer)
        addLayer(layerName, color: color)

        var entity = [String]()
        appendPair(0, "ARC", to: &entity)
        appendPair(100, "AcDbEntity", to: &entity)
        appendPair(8, layerName, to: &entity)
        appendPair(420, trueColor(color), to: &entity)
        appendPair(370, lineWeight(width), to: &entity)
        appendPair(100, "AcDbCircle", to: &entity)
        appendPair(10, mm(center.x), to: &entity)
        appendPair(20, mm(center.y), to: &entity)
        appendPair(30, "0.0", to: &entity)
        appendPair(40, mm(radius), to: &entity)
        appendPair(100, "AcDbArc", to: &entity)
        appendPair(50, arc.reverse ? toAngle : fromAngle, to: &entity)
        appendPair(51, arc.reverse ? fromAngle : toAngle, to: &entity)
        entities.append(entity.joined())
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = [String]()

        appendPair(0, "SECTION", to: &lines)
        appendPair(2, "HEADER", to: &lines)
        appendPair(9, "$ACADVER", to: &lines)
        appendPair(1, "AC1015", to: &lines)
        appendPair(9, "$INSUNITS", to: &lines)
        appendPair(70, 4, to: &lines)
        appendPair(0, "ENDSEC", to: &lines)

        appendPair(0, "SECTION", to: &lines)
        appendPair(2, "TABLES", to: &lines)
        appendPair(0, "TABLE", to: &lines)
        appendPair(2, "LAYER", to: &lines)
        appendPair(70, layerOrder.count, to: &lines)
        for layerName in layerOrder {
            guard let layer = layers[layerName] else {
                continue
            }
            appendPair(0, "LAYER", to: &lines)
            appendPair(100, "AcDbSymbolTableRecord", to: &lines)
            appendPair(100, "AcDbLayerTableRecord", to: &lines)
            appendPair(2, layer.name, to: &lines)
            appendPair(70, 0, to: &lines)
            appendPair(62, aciColor(layer.color), to: &lines)
            appendPair(420, trueColor(layer.color), to: &lines)
            appendPair(6, "CONTINUOUS", to: &lines)
        }
        appendPair(0, "ENDTAB", to: &lines)
        appendPair(0, "ENDSEC", to: &lines)

        appendPair(0, "SECTION", to: &lines)
        appendPair(2, "ENTITIES", to: &lines)
        lines.append(contentsOf: entities)
        appendPair(0, "ENDSEC", to: &lines)
        appendPair(0, "EOF", to: &lines)

        try Data(lines.joined().utf8).write(to: url, options: [.atomic])
    }

    private mutating func addSolidHatch(_ points: [HorizontalPoint], layer: String, color: HorizontalRGBColor) {
        let hatchPoints = normalizedPolylinePoints(points, closed: true)
        guard hatchPoints.count >= 3 else {
            return
        }

        let layerName = sanitizedLayerName(layer)
        addLayer(layerName, color: color)
        var entity = [String]()
        appendPair(0, "HATCH", to: &entity)
        appendPair(100, "AcDbEntity", to: &entity)
        appendPair(8, layerName, to: &entity)
        appendPair(420, trueColor(color), to: &entity)
        appendPair(100, "AcDbHatch", to: &entity)
        appendPair(10, "0.0", to: &entity)
        appendPair(20, "0.0", to: &entity)
        appendPair(30, "0.0", to: &entity)
        appendPair(210, "0.0", to: &entity)
        appendPair(220, "0.0", to: &entity)
        appendPair(230, "1.0", to: &entity)
        appendPair(2, "SOLID", to: &entity)
        appendPair(70, 1, to: &entity)
        appendPair(71, 0, to: &entity)
        appendPair(91, 1, to: &entity)
        appendPair(92, 7, to: &entity)
        appendPair(72, 1, to: &entity)
        appendPair(73, 1, to: &entity)
        appendPair(93, hatchPoints.count, to: &entity)
        for point in hatchPoints {
            appendPair(10, mm(point.x), to: &entity)
            appendPair(20, mm(point.y), to: &entity)
        }
        appendPair(97, 0, to: &entity)
        appendPair(75, 0, to: &entity)
        appendPair(76, 1, to: &entity)
        appendPair(98, 0, to: &entity)
        entities.append(entity.joined())
    }
}

private func appendPair(_ code: Int, _ value: String, to lines: inout [String]) {
    lines.append("\(code)\n\(value)\n")
}

private func appendPair(_ code: Int, _ value: Int, to lines: inout [String]) {
    appendPair(code, String(value), to: &lines)
}

private func appendPair(_ code: Int, _ value: Double, to lines: inout [String]) {
    appendPair(code, String(format: "%.6f", value), to: &lines)
}

private func mm(_ value: Double) -> Double {
    value / 1_000_000
}

private func lineWeight(_ width: Double) -> Int {
    min(max(Int((mm(width) * 100).rounded()), 0), 2_111)
}

private func degrees(_ radians: Double) -> Double {
    var value = radians * 180 / Double.pi
    while value < 0 {
        value += 360
    }
    while value >= 360 {
        value -= 360
    }
    return value
}

private func trueColor(_ color: HorizontalRGBColor) -> Int {
    let red = min(max(Int((color.red * 255).rounded()), 0), 255)
    let green = min(max(Int((color.green * 255).rounded()), 0), 255)
    let blue = min(max(Int((color.blue * 255).rounded()), 0), 255)
    return red << 16 | green << 8 | blue
}

private func aciColor(_ color: HorizontalRGBColor) -> Int {
    let red = color.red
    let green = color.green
    let blue = color.blue
    let brightness = max(red, green, blue)
    guard brightness > 0.08 else {
        return 7
    }
    if red > green * 1.35 && red > blue * 1.35 {
        return 1
    }
    if green > red * 1.35 && green > blue * 1.35 {
        return 3
    }
    if blue > red * 1.35 && blue > green * 1.35 {
        return 5
    }
    if red > 0.7 && green > 0.7 && blue < 0.35 {
        return 2
    }
    if green > 0.55 && blue > 0.55 && red < 0.35 {
        return 4
    }
    if red > 0.55 && blue > 0.55 && green < 0.35 {
        return 6
    }
    return 7
}

private func sanitizedLayerName(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "<>/\\\":;?*|=`,")
        .union(.newlines)
        .union(.controlCharacters)
    let sanitized = name
        .components(separatedBy: invalid)
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "Layer" : sanitized
}

private func normalizedPolylinePoints(_ points: [HorizontalPoint], closed: Bool) -> [HorizontalPoint] {
    var normalized = points
    while normalized.count > 1, normalized.first == normalized.last {
        normalized.removeLast()
    }
    guard closed, normalized.count >= 3 else {
        return normalized
    }
    return normalized
}

private func dxfPolylinePoints(_ points: [HorizontalPoint], closed: Bool) -> [HorizontalPoint] {
    var normalized = normalizedPolylinePoints(points, closed: closed)
    guard closed,
          normalized.count >= 3,
          let first = normalized.first else {
        return normalized
    }
    normalized.append(first)
    return normalized
}

private func gerberApertureCapsule(
    from: HorizontalPoint,
    to: HorizontalPoint,
    width: Double,
    segments: Int = 12
) -> [HorizontalPoint]? {
    let radius = width / 2
    let vector = to - from
    let length = vector.length
    guard radius.isFinite,
          radius > 0,
          length.isFinite,
          length > 0.5 else {
        return nil
    }

    let direction = vector * (1 / length)
    let normal = HorizontalPoint(x: -direction.y, y: direction.x)
    let theta = atan2(direction.y, direction.x)
    let capSegments = max(segments, 2)

    var points = [HorizontalPoint]()
    points.reserveCapacity(capSegments * 2 + 4)
    points.append(from + normal * radius)
    points.append(to + normal * radius)

    for index in 1...capSegments {
        let angle = theta + Double.pi / 2 - Double(index) / Double(capSegments) * Double.pi
        points.append(to + HorizontalPoint(x: cos(angle) * radius, y: sin(angle) * radius))
    }

    points.append(from - normal * radius)

    for index in 1...capSegments {
        let angle = theta - Double.pi / 2 - Double(index) / Double(capSegments) * Double.pi
        points.append(from + HorizontalPoint(x: cos(angle) * radius, y: sin(angle) * radius))
    }

    return points
}

private struct DrillHit {
    var position: HorizontalPoint
    var diameter: Double
    var plated: Bool
}

private struct ODBLayer {
    var id: Int
    var name: String
    var type: String
    var context: String
    var objects: [GerberPrimitive]
}

private extension HorizontalRGBColor {
    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: alpha)
    }
}

private func rgbColor(from color: Color) -> HorizontalRGBColor {
    #if os(macOS)
    let nsColor = NSColor(color)
    let converted = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
    return HorizontalRGBColor(
        red: Double(converted.redComponent),
        green: Double(converted.greenComponent),
        blue: Double(converted.blueComponent)
    )
    #else
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return HorizontalRGBColor(red: Double(red), green: Double(green), blue: Double(blue))
    #endif
}

private struct HorizontalExportError: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct BOMRowKey: Hashable {
    var mpn: String
    var value: String
    var manufacturer: String
    var packageName: String
    var description: String
    var datasheet: String
}

private struct BOMRow {
    var key: BOMRowKey
    var refdes: [String]

    var quantity: String {
        refdes.count.formatted()
    }

    func value(for column: HorizontalBOMColumn) -> String {
        switch column {
        case .quantity: quantity
        case .mpn: key.mpn
        case .value: key.value
        case .manufacturer: key.manufacturer
        case .refdes: refdes.joined(separator: ", ")
        case .package: key.packageName
        case .datasheet: key.datasheet
        case .description: key.description
        }
    }
}

private struct PnPRow {
    var refdes: String
    var x: String
    var y: String
    var angle: String
    var side: String
    var mpn: String
    var value: String
    var manufacturer: String
    var packageName: String

    init(package: HorizontalPlacement, settings: HorizontalPnPExportSettings) {
        let details = package.componentDetails
        refdes = details?.refdes ?? package.label
        x = Self.formatPosition(package.position.x, format: settings.positionFormat)
        y = Self.formatPosition(package.position.y, format: settings.positionFormat)
        angle = Self.formatAngle(package.angle)
        side = package.mirrored ? settings.bottomSide : settings.topSide
        mpn = details?.mpn ?? ""
        value = details?.value ?? ""
        manufacturer = details?.manufacturer ?? ""
        packageName = details?.packageName ?? package.packageID ?? ""
    }

    func value(for column: HorizontalPnPColumn) -> String {
        switch column {
        case .refdes: refdes
        case .x: x
        case .y: y
        case .angle: angle
        case .side: side
        case .mpn: mpn
        case .value: value
        case .manufacturer: manufacturer
        case .package: packageName
        }
    }

    private static func formatPosition(_ value: Double, format: String) -> String {
        let millimeters = value / 1_000_000
        let precision: Int
        if let match = format.range(of: #"(?<=%\.)\d+(?=m)"#, options: .regularExpression),
           let parsed = Int(format[match]) {
            precision = parsed
        } else {
            precision = 3
        }
        return String(format: "%.\(precision)f", millimeters)
    }

    private static func formatAngle(_ angle: Int) -> String {
        let degrees = Double(angle) / 65_536.0 * 360.0
        return String(format: "%.3f", degrees)
    }
}
