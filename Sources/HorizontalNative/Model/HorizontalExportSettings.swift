import Foundation

struct HorizontalExportStatus: Equatable {
    enum Kind {
        case info
        case success
        case warning
        case error
    }

    var kind: Kind
    var message: String
}

enum HorizontalExportPathError: LocalizedError, Equatable {
    case insideProject(target: URL, project: URL)

    var errorDescription: String? {
        switch self {
        case let .insideProject(_, project):
            "Export directory must be outside \(project.lastPathComponent)."
        }
    }
}

enum HorizontalExportSection: String, CaseIterable, Identifiable {
    case schematicPDF
    case bom
    case gerber
    case odb
    case pickAndPlace
    case boardSTEP
    case boardDrawing
    case boardDXF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .schematicPDF: "Schematic PDF"
        case .bom: "Bill of Materials (BOM)"
        case .gerber: "Gerber"
        case .odb: "ODB"
        case .pickAndPlace: "Pick and Place"
        case .boardSTEP: "3D Model"
        case .boardDrawing: "Board Drawing"
        case .boardDXF: "Board DXF"
        }
    }

    var symbolName: String {
        switch self {
        case .schematicPDF: "doc.richtext"
        case .bom: "tablecells"
        case .gerber: "shippingbox"
        case .odb: "archivebox"
        case .pickAndPlace: "point.topleft.down.curvedto.point.bottomright.up"
        case .boardSTEP: "cube"
        case .boardDrawing: "doc.text.image"
        case .boardDXF: "rectangle.3.group"
        }
    }
}

enum HorizontalExportSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }
    var title: String { self == .ascending ? "Ascending" : "Descending" }
}

enum HorizontalBOMColumn: String, CaseIterable, Identifiable {
    case quantity
    case mpn
    case value
    case manufacturer
    case refdes
    case package
    case datasheet
    case description

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quantity: "QTY"
        case .mpn: "MPN"
        case .value: "Value"
        case .manufacturer: "Manufacturer"
        case .refdes: "Ref. Des."
        case .package: "Package"
        case .datasheet: "Datasheet"
        case .description: "Description"
        }
    }
}

enum HorizontalPnPColumn: String, CaseIterable, Identifiable {
    case refdes
    case x
    case y
    case angle
    case side
    case mpn
    case value
    case manufacturer
    case package

    var id: String { rawValue }

    var title: String {
        switch self {
        case .refdes: "Ref. Des."
        case .x: "X"
        case .y: "Y"
        case .angle: "Angle"
        case .side: "Side"
        case .mpn: "MPN"
        case .value: "Value"
        case .manufacturer: "Manufacturer"
        case .package: "Package"
        }
    }
}

enum HorizontalPnPExportMode: String, CaseIterable, Identifiable {
    case merged
    case individual

    var id: String { rawValue }
    var title: String { self == .merged ? "Merged" : "Individual" }
}

enum HorizontalGerberDrillMode: String, CaseIterable, Identifiable {
    case merged
    case individual

    var id: String { rawValue }
    var title: String { self == .merged ? "Merged" : "Individual" }
}

enum HorizontalODBExportFormat: String, CaseIterable, Identifiable {
    case tgz
    case directory
    case zip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tgz: "Tarball (.tgz)"
        case .directory: "Directory"
        case .zip: "ZIP archive (.zip)"
        }
    }
}

enum HorizontalPDFLayerMode: String, CaseIterable, Identifiable {
    case fill
    case outline

    var id: String { rawValue }
    var title: String { self == .fill ? "Fill" : "Outline" }
}

struct HorizontalExportLayerSetting: Identifiable, Hashable {
    var layer: Int
    var name: String
    var enabled: Bool
    var filename: String
    var mode: HorizontalPDFLayerMode
    var color: HorizontalRGBColor

    var id: Int { layer }
}

struct HorizontalSchematicPDFExportSettings: Hashable {
    var enabled = true
    var filename: String
    var minimumLineWidthMM = 0.0
}

struct HorizontalBOMExportSettings: Hashable {
    var enabled = true
    var filename: String
    var sortColumn: HorizontalBOMColumn = .refdes
    var sortOrder: HorizontalExportSortOrder = .ascending
    var includeNoPopulate = true
    var customizeFormat = false
    var columns: Set<HorizontalBOMColumn> = [.quantity, .mpn, .value, .manufacturer, .refdes]
}

struct HorizontalGerberExportSettings: Hashable {
    var enabled = true
    var prefix: String
    var zipOutput = true
    var removeIndividualFilesAfterZip = true
    var drillMode: HorizontalGerberDrillMode = .merged
    var drillPTHSuffix = " Drills.drl"
    var drillNPTHSuffix = " NPTH Drills.drl"
    var outlineWidthMM = 0.01
    var layers: [HorizontalExportLayerSetting] = []
}

struct HorizontalODBExportSettings: Hashable {
    var enabled = true
    var format: HorizontalODBExportFormat = .zip
    var filename: String
    var directoryName: String
    var jobName: String
}

struct HorizontalPnPExportSettings: Hashable {
    var enabled = true
    var mode: HorizontalPnPExportMode = .merged
    var filenameMerged: String
    var filenameTop: String
    var filenameBottom: String
    var includeNoPopulate = true
    var customizeFormat = false
    var positionFormat = "%.3m"
    var topSide = "top"
    var bottomSide = "bottom"
    var columns: Set<HorizontalPnPColumn> = [.refdes, .x, .y, .angle, .side]
}

struct HorizontalSTEPExportSettings: Hashable {
    var enabled = true
    var filename: String
    var labelPrefix: String
    var include3DModels = true
    var minimumHoleDiameterMM = 0.0
}

struct HorizontalBoardDrawingExportSettings: Hashable {
    var enabled = true
    var filename: String
    var minimumLineWidthMM = 0.1
    var reverseLayers = false
    var mirrored = false
    var useSpecifiedHoleDiameter = false
    var holeDiameterMM = 0.0
    var layers: [HorizontalExportLayerSetting] = []
}

struct HorizontalBoardDXFExportSettings: Hashable {
    var enabled = true
    var filename: String
    var minimumLineWidthMM = 0.1
    var includeHoles = true
    var includeDimensions = true
    var layers: [HorizontalExportLayerSetting] = []
}

struct HorizontalExportSettings: Hashable {
    var targetDirectory: String
    var schematicPDF: HorizontalSchematicPDFExportSettings
    var bom: HorizontalBOMExportSettings
    var gerber: HorizontalGerberExportSettings
    var odb: HorizontalODBExportSettings
    var pickAndPlace: HorizontalPnPExportSettings
    var boardSTEP: HorizontalSTEPExportSettings
    var boardDrawing: HorizontalBoardDrawingExportSettings
    var boardDXF: HorizontalBoardDXFExportSettings

    init(project: HorizontalProject) {
        let projectShortName = Self.projectShortName(for: project)
        let gerberBaseName = "\(projectShortName) Gerbers"
        let odbBaseName = "\(projectShortName) ODB"
        targetDirectory = Self.defaultExportDirectory(for: project).path
        schematicPDF = HorizontalSchematicPDFExportSettings(filename: "\(projectShortName) Schematic.pdf")
        bom = HorizontalBOMExportSettings(filename: "\(projectShortName) BOM.csv")
        gerber = HorizontalGerberExportSettings(prefix: gerberBaseName)
        odb = HorizontalODBExportSettings(filename: "\(odbBaseName).zip", directoryName: odbBaseName, jobName: projectShortName)
        pickAndPlace = HorizontalPnPExportSettings(
            filenameMerged: "\(projectShortName) Pick And Place.csv",
            filenameTop: "\(projectShortName) Top Pick And Place.csv",
            filenameBottom: "\(projectShortName) Bottom Pick And Place.csv"
        )
        boardSTEP = HorizontalSTEPExportSettings(filename: "\(projectShortName) Model.step", labelPrefix: projectShortName)
        boardDrawing = HorizontalBoardDrawingExportSettings(filename: "\(projectShortName) Board Drawing.pdf")
        boardDXF = HorizontalBoardDXFExportSettings(filename: "\(projectShortName) Board Drawing.dxf")
        refreshBoardLayers(from: project.board)
    }

    static func exportTargetDirectory(for project: HorizontalProject, requestedPath: String) throws -> URL {
        let defaultURL = defaultExportDirectory(for: project)
        let trimmedPath = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedURL = trimmedPath.isEmpty
            ? defaultURL
            : resolvedExportDirectoryURL(for: project, path: trimmedPath)

        guard let packageURL = horizontalPackageURL(for: project) else {
            return requestedURL
        }

        guard !isInsideOrEqual(requestedURL, directory: packageURL) else {
            throw HorizontalExportPathError.insideProject(target: requestedURL, project: packageURL)
        }
        return requestedURL
    }

    mutating func refreshBoardLayers(from board: HorizontalBoard?) {
        let gerberLayers = Self.gerberLayers(for: board)
        if gerber.layers.map(\.layer) != gerberLayers.map(\.layer) {
            gerber.layers = gerberLayers
        }

        let pdfLayers = Self.pdfLayers(for: board)
        if boardDrawing.layers.map(\.layer) != pdfLayers.map(\.layer) {
            boardDrawing.layers = pdfLayers
        }

        let dxfLayers = Self.dxfLayers(for: board)
        if boardDXF.layers.map(\.layer) != dxfLayers.map(\.layer) {
            boardDXF.layers = dxfLayers
        }
    }

    func isEnabled(_ section: HorizontalExportSection) -> Bool {
        switch section {
        case .schematicPDF: schematicPDF.enabled
        case .bom: bom.enabled
        case .gerber: gerber.enabled
        case .odb: odb.enabled
        case .pickAndPlace: pickAndPlace.enabled
        case .boardSTEP: boardSTEP.enabled
        case .boardDrawing: boardDrawing.enabled
        case .boardDXF: boardDXF.enabled
        }
    }

    static func sanitizedFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Horizontal" : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        return source
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func defaultExportDirectory(for project: HorizontalProject) -> URL {
        let exportName = "\(projectShortName(for: project)) Export"
        return exportBaseDirectory(for: project)
            .appendingPathComponent(exportName, isDirectory: true)
            .standardizedFileURL
    }

    static func exportBaseDirectory(for project: HorizontalProject) -> URL {
        let projectURL = horizontalPackageURL(for: project) ?? project.projectFileURL
        return projectURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func projectShortName(for project: HorizontalProject) -> String {
        let projectURL = horizontalPackageURL(for: project) ?? project.projectFileURL
        return sanitizedFilename(projectURL.deletingPathExtension().lastPathComponent)
    }

    private static func resolvedExportDirectoryURL(for project: HorizontalProject, path: String) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        }
        return exportBaseDirectory(for: project)
            .appendingPathComponent(expandedPath, isDirectory: true)
            .standardizedFileURL
    }

    private static func horizontalPackageURL(for project: HorizontalProject) -> URL? {
        [project.url, project.baseURL, project.projectFileURL.deletingLastPathComponent()]
            .map(\.standardizedFileURL)
            .first { $0.pathExtension.caseInsensitiveCompare("horizontal") == .orderedSame }
    }

    private static func isInsideOrEqual(_ url: URL, directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    private static func gerberLayers(for board: HorizontalBoard?) -> [HorizontalExportLayerSetting] {
        gerberLayerIDs(for: board).map { layer in
            HorizontalExportLayerSetting(
                layer: layer,
                name: HorizontalBoardLayers.name(for: layer),
                enabled: true,
                filename: defaultGerberSuffix(for: layer),
                mode: .fill,
                color: defaultLayerColor(for: layer)
            )
        }
    }

    private static func pdfLayers(for board: HorizontalBoard?) -> [HorizontalExportLayerSetting] {
        pdfLayerIDs(for: board).map { layer in
            HorizontalExportLayerSetting(
                layer: layer,
                name: HorizontalBoardLayers.name(for: layer),
                enabled: defaultPDFLayerEnabled(for: layer),
                filename: "",
                mode: HorizontalBoardLayers.isOutline(layer) ? .outline : .fill,
                color: defaultPDFLayerColor(for: layer)
            )
        }
    }

    private static func dxfLayers(for board: HorizontalBoard?) -> [HorizontalExportLayerSetting] {
        pdfLayerIDs(for: board).map { layer in
            HorizontalExportLayerSetting(
                layer: layer,
                name: HorizontalBoardLayers.name(for: layer),
                enabled: true,
                filename: "",
                mode: HorizontalBoardLayers.isOutline(layer) ? .outline : .fill,
                color: defaultLayerColor(for: layer)
            )
        }
    }

    private static func gerberLayerIDs(for board: HorizontalBoard?) -> [Int] {
        let fixedLayers = [
            HorizontalBoardLayers.outlineNotes,
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
        guard let board else {
            return fixedLayers
        }

        let boardLayers = Set(
            fixedLayers
                + board.stackupLayers.map(\.layer)
                + board.userLayers.map(\.id)
        )
        return HorizontalBoardLayers.all.filter { boardLayers.contains($0) }
    }

    private static func pdfLayerIDs(for board: HorizontalBoard?) -> [Int] {
        let fixedLayers = [
            HorizontalBoardLayers.topNotes,
            HorizontalBoardLayers.outlineNotes,
            HorizontalBoardLayers.outline,
            HorizontalBoardLayers.topAssembly,
            HorizontalBoardLayers.topPackage,
            HorizontalBoardLayers.topPaste,
            HorizontalBoardLayers.topSilkscreen,
            HorizontalBoardLayers.topMask,
            HorizontalBoardLayers.topCopper,
            HorizontalBoardLayers.bottomCopper,
            HorizontalBoardLayers.bottomMask,
            HorizontalBoardLayers.bottomSilkscreen,
            HorizontalBoardLayers.bottomPaste,
            HorizontalBoardLayers.bottomPackage,
            HorizontalBoardLayers.bottomAssembly,
            HorizontalBoardLayers.bottomNotes
        ]
        guard let board else {
            return fixedLayers
        }

        let boardLayers = Set(
            fixedLayers
                + board.stackupLayers.map(\.layer)
                + board.userLayers.map(\.id)
        )
        return HorizontalBoardLayers.all.filter { boardLayers.contains($0) }
    }

    private static func defaultPDFLayerEnabled(for layer: Int) -> Bool {
        if HorizontalBoardLayers.isBottomSide(layer) {
            return false
        }
        if layer < HorizontalBoardLayers.topCopper && layer > HorizontalBoardLayers.bottomCopper {
            return false
        }
        return true
    }

    private static func defaultPDFLayerColor(for layer: Int) -> HorizontalRGBColor {
        HorizontalRGBColor(red: 0, green: 0, blue: 0)
    }

    private static func defaultGerberSuffix(for layer: Int) -> String {
        switch layer {
        case HorizontalBoardLayers.outline: " Outline.gbr"
        default: " \(sanitizedFilename(HorizontalBoardLayers.name(for: layer))).gbr"
        }
    }

    private static func defaultLayerColor(for layer: Int) -> HorizontalRGBColor {
        switch layer {
        case HorizontalBoardLayers.topNotes, HorizontalBoardLayers.bottomNotes:
            return HorizontalRGBColor(red: 0, green: 0, blue: 0)
        case HorizontalBoardLayers.outline, HorizontalBoardLayers.outlineNotes:
            return HorizontalRGBColor(red: 0.6, green: 0.6, blue: 0)
        case HorizontalBoardLayers.topCopper:
            return HorizontalRGBColor(red: 1, green: 0, blue: 0)
        case HorizontalBoardLayers.bottomCopper:
            return HorizontalRGBColor(red: 0, green: 0.5, blue: 0)
        case HorizontalBoardLayers.topMask:
            return HorizontalRGBColor(red: 1, green: 0.5, blue: 0.5)
        case HorizontalBoardLayers.bottomMask:
            return HorizontalRGBColor(red: 0.25, green: 0.5, blue: 0.25)
        case HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen:
            return HorizontalRGBColor(red: 0, green: 0, blue: 0)
        case HorizontalBoardLayers.topPaste, HorizontalBoardLayers.bottomPaste:
            return HorizontalRGBColor(red: 0.8, green: 0.8, blue: 0.8)
        default:
            if HorizontalBoardLayers.isCopper(layer) {
                return HorizontalRGBColor(red: 1, green: 1, blue: 0)
            }
            if HorizontalBoardLayers.isUser(layer) {
                return HorizontalRGBColor(red: 0.25, green: 1, blue: 1)
            }
            return HorizontalRGBColor(red: 0, green: 0, blue: 0)
        }
    }
}
