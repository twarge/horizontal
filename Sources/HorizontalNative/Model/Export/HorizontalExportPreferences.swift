import Foundation

/// What the Export sidebar's choices come to once the project is taken out
/// of them: which sections Export All writes, and each section's options.
/// The app remembers these, so a section turned off, or a BOM's columns,
/// stay as they were chosen in the next window and at the next launch.
///
/// What belongs to a project is left out and made afresh for each: the
/// folder, the file names, which are the project's name, and the layers,
/// which are its board's. MCP's export doesn't read these either: it names
/// its sections and passes its options, and answers the same on every Mac.
///
/// Every field is optional, so what an older or a newer build saved still
/// reads, each choice it doesn't have staying as the app has it by default.
struct HorizontalExportPreferences: Codable, Equatable {
    static let defaultsKey = "export.preferences"

    var enabledSections: [String: Bool]?

    var schematicMinimumLineWidthMM: Double?

    var bomSortColumn: String?
    var bomSortOrder: String?
    var bomIncludeNoPopulate: Bool?
    var bomCustomizeFormat: Bool?
    var bomColumns: [String]?

    var gerberZipOutput: Bool?
    var gerberRemoveIndividualFilesAfterZip: Bool?
    var gerberDrillMode: String?
    var gerberOutlineWidthMM: Double?

    var odbFormat: String?

    var pnpMode: String?
    var pnpIncludeNoPopulate: Bool?
    var pnpCustomizeFormat: Bool?
    var pnpPositionFormat: String?
    var pnpTopSide: String?
    var pnpBottomSide: String?
    var pnpColumns: [String]?

    var stepInclude3DModels: Bool?
    var stepMinimumHoleDiameterMM: Double?
    var stepCopperLayers: String?
    var stepOmitSmallComponents: Bool?
    var stepMinimumComponentSizeMM: Double?

    var drawingMinimumLineWidthMM: Double?
    var drawingReverseLayers: Bool?
    var drawingMirrored: Bool?
    var drawingUseSpecifiedHoleDiameter: Bool?
    var drawingHoleDiameterMM: Double?

    var dxfMinimumLineWidthMM: Double?
    var dxfIncludeHoles: Bool?
    var dxfIncludeDimensions: Bool?

    init() {}

    /// The choices `settings` holds.
    init(_ settings: HorizontalExportSettings) {
        enabledSections = HorizontalExportSection.allCases.reduce(into: [String: Bool]()) {
            $0[$1.rawValue] = settings.isEnabled($1)
        }
        schematicMinimumLineWidthMM = settings.schematicPDF.minimumLineWidthMM

        bomSortColumn = settings.bom.sortColumn.rawValue
        bomSortOrder = settings.bom.sortOrder.rawValue
        bomIncludeNoPopulate = settings.bom.includeNoPopulate
        bomCustomizeFormat = settings.bom.customizeFormat
        bomColumns = settings.bom.columns.map(\.rawValue).sorted()

        gerberZipOutput = settings.gerber.zipOutput
        gerberRemoveIndividualFilesAfterZip = settings.gerber.removeIndividualFilesAfterZip
        gerberDrillMode = settings.gerber.drillMode.rawValue
        gerberOutlineWidthMM = settings.gerber.outlineWidthMM

        odbFormat = settings.odb.format.rawValue

        pnpMode = settings.pickAndPlace.mode.rawValue
        pnpIncludeNoPopulate = settings.pickAndPlace.includeNoPopulate
        pnpCustomizeFormat = settings.pickAndPlace.customizeFormat
        pnpPositionFormat = settings.pickAndPlace.positionFormat
        pnpTopSide = settings.pickAndPlace.topSide
        pnpBottomSide = settings.pickAndPlace.bottomSide
        pnpColumns = settings.pickAndPlace.columns.map(\.rawValue).sorted()

        stepInclude3DModels = settings.boardSTEP.include3DModels
        stepMinimumHoleDiameterMM = settings.boardSTEP.minimumHoleDiameterMM
        stepCopperLayers = settings.boardSTEP.copperLayers.rawValue
        stepOmitSmallComponents = settings.boardSTEP.omitSmallComponents
        stepMinimumComponentSizeMM = settings.boardSTEP.minimumComponentSizeMM

        drawingMinimumLineWidthMM = settings.boardDrawing.minimumLineWidthMM
        drawingReverseLayers = settings.boardDrawing.reverseLayers
        drawingMirrored = settings.boardDrawing.mirrored
        drawingUseSpecifiedHoleDiameter = settings.boardDrawing.useSpecifiedHoleDiameter
        drawingHoleDiameterMM = settings.boardDrawing.holeDiameterMM

        dxfMinimumLineWidthMM = settings.boardDXF.minimumLineWidthMM
        dxfIncludeHoles = settings.boardDXF.includeHoles
        dxfIncludeDimensions = settings.boardDXF.includeDimensions
    }

    /// Makes `settings` the remembered choices, where one is remembered and
    /// still means something: a column or a mode this build doesn't know is
    /// passed over.
    func apply(to settings: inout HorizontalExportSettings) {
        func set<Value>(_ keyPath: WritableKeyPath<HorizontalExportSettings, Value>, _ value: Value?) {
            if let value {
                settings[keyPath: keyPath] = value
            }
        }
        func width(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        if let enabledSections {
            for section in HorizontalExportSection.allCases {
                if let enabled = enabledSections[section.rawValue] {
                    settings.setEnabled(enabled, for: section)
                }
            }
        }
        set(\.schematicPDF.minimumLineWidthMM, width(schematicMinimumLineWidthMM))

        set(\.bom.sortColumn, bomSortColumn.flatMap(HorizontalBOMColumn.init(rawValue:)))
        set(\.bom.sortOrder, bomSortOrder.flatMap(HorizontalExportSortOrder.init(rawValue:)))
        set(\.bom.includeNoPopulate, bomIncludeNoPopulate)
        set(\.bom.customizeFormat, bomCustomizeFormat)
        set(\.bom.columns, bomColumns.map { Set($0.compactMap(HorizontalBOMColumn.init(rawValue:))) })

        set(\.gerber.zipOutput, gerberZipOutput)
        set(\.gerber.removeIndividualFilesAfterZip, gerberRemoveIndividualFilesAfterZip)
        set(\.gerber.drillMode, gerberDrillMode.flatMap(HorizontalGerberDrillMode.init(rawValue:)))
        set(\.gerber.outlineWidthMM, width(gerberOutlineWidthMM))

        set(\.odb.format, odbFormat.flatMap(HorizontalODBExportFormat.init(rawValue:)))

        set(\.pickAndPlace.mode, pnpMode.flatMap(HorizontalPnPExportMode.init(rawValue:)))
        set(\.pickAndPlace.includeNoPopulate, pnpIncludeNoPopulate)
        set(\.pickAndPlace.customizeFormat, pnpCustomizeFormat)
        set(\.pickAndPlace.positionFormat, pnpPositionFormat)
        set(\.pickAndPlace.topSide, pnpTopSide)
        set(\.pickAndPlace.bottomSide, pnpBottomSide)
        set(\.pickAndPlace.columns, pnpColumns.map { Set($0.compactMap(HorizontalPnPColumn.init(rawValue:))) })

        set(\.boardSTEP.include3DModels, stepInclude3DModels)
        set(\.boardSTEP.minimumHoleDiameterMM, width(stepMinimumHoleDiameterMM))
        set(\.boardSTEP.copperLayers, stepCopperLayers.flatMap(HorizontalSTEPCopperLayers.init(rawValue:)))
        set(\.boardSTEP.omitSmallComponents, stepOmitSmallComponents)
        set(\.boardSTEP.minimumComponentSizeMM, width(stepMinimumComponentSizeMM))

        set(\.boardDrawing.minimumLineWidthMM, width(drawingMinimumLineWidthMM))
        set(\.boardDrawing.reverseLayers, drawingReverseLayers)
        set(\.boardDrawing.mirrored, drawingMirrored)
        set(\.boardDrawing.useSpecifiedHoleDiameter, drawingUseSpecifiedHoleDiameter)
        set(\.boardDrawing.holeDiameterMM, width(drawingHoleDiameterMM))

        set(\.boardDXF.minimumLineWidthMM, width(dxfMinimumLineWidthMM))
        set(\.boardDXF.includeHoles, dxfIncludeHoles)
        set(\.boardDXF.includeDimensions, dxfIncludeDimensions)
    }

    /// What was remembered, nil where nothing was or it can't be read.
    static func load(from defaults: UserDefaults = .standard) -> HorizontalExportPreferences? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(HorizontalExportPreferences.self, from: $0) }
    }

    /// Remembers these choices; nothing is written where they are the ones
    /// remembered already.
    func save(to defaults: UserDefaults = .standard) {
        guard Self.load(from: defaults) != self else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension HorizontalExportSettings {
    /// A project window's export settings: named and placed for the project,
    /// with the choices the app remembers.
    static func remembered(for project: HorizontalProject, defaults: UserDefaults = .standard) -> HorizontalExportSettings {
        var settings = HorizontalExportSettings(project: project)
        HorizontalExportPreferences.load(from: defaults)?.apply(to: &settings)
        return settings
    }

    mutating func setEnabled(_ enabled: Bool, for section: HorizontalExportSection) {
        switch section {
        case .schematicPDF: schematicPDF.enabled = enabled
        case .bom: bom.enabled = enabled
        case .gerber: gerber.enabled = enabled
        case .odb: odb.enabled = enabled
        case .pickAndPlace: pickAndPlace.enabled = enabled
        case .boardSTEP: boardSTEP.enabled = enabled
        case .boardDrawing: boardDrawing.enabled = enabled
        case .boardDXF: boardDXF.enabled = enabled
        }
    }
}
