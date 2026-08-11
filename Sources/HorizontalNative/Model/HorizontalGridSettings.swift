import Foundation

struct HorizontalGridSettings: Hashable {
    static let minimumSpacing = 10_000.0
    static let maximumSpacing = 10_000_000.0
    static let minimumOrigin = -1_000_000_000.0
    static let maximumOrigin = 1_000_000_000.0

    var name: String
    var mode: String
    var spacingSquare: Double
    var spacingRect: HorizontalPoint
    var origin: HorizontalPoint

    var spacing: HorizontalPoint {
        mode == "rect" ? spacingRect : HorizontalPoint(x: spacingSquare, y: spacingSquare)
    }

    init(name: String, mode: String, spacing: HorizontalPoint, origin: HorizontalPoint) {
        let sanitizedMode = mode == "rect" ? "rect" : "square"
        self.name = name
        self.mode = sanitizedMode
        self.spacingSquare = Self.sanitizedSpacing(spacing.x, fallback: Self.boardDefaultSquareSpacing)
        self.spacingRect = Self.sanitizedSpacing(spacing, fallback: Self.boardDefaultRectSpacing)
        self.origin = Self.clampedOrigin(origin)
    }

    init(
        name: String,
        mode: String,
        spacingSquare: Double,
        spacingRect: HorizontalPoint,
        origin: HorizontalPoint
    ) {
        self.name = name
        self.mode = mode == "rect" ? "rect" : "square"
        self.spacingSquare = Self.sanitizedSpacing(spacingSquare, fallback: Self.boardDefaultSquareSpacing)
        self.spacingRect = Self.sanitizedSpacing(spacingRect, fallback: Self.boardDefaultRectSpacing)
        self.origin = Self.clampedOrigin(origin)
    }

    static let boardDefault = HorizontalGridSettings(
        name: "",
        mode: "square",
        spacingSquare: boardDefaultSquareSpacing,
        spacingRect: boardDefaultRectSpacing,
        origin: .zero
    )

    static let schematicDefault = HorizontalGridSettings(
        name: "",
        mode: "square",
        spacingSquare: schematicFixedSpacing,
        spacingRect: HorizontalPoint(x: schematicFixedSpacing, y: schematicFixedSpacing),
        origin: .zero
    )

    private static let boardDefaultSquareSpacing = 1_000_000.0
    private static let boardDefaultRectSpacing = HorizontalPoint(x: 1_000_000, y: 1_000_000)
    private static let schematicFixedSpacing = 1_250_000.0

    static func load(from documentJSON: JSONDictionary, fileURL: URL, defaultGrid: HorizontalGridSettings) -> HorizontalGridSettings {
        if defaultGrid == schematicDefault {
            return schematicDefault
        }

        if let current = documentJSON.dictionary("grid_settings")?.dictionary("current") {
            return parseCurrentGrid(from: current, defaultGrid: defaultGrid)
        }

        let metaURL = URL(fileURLWithPath: fileURL.path + ".imp_meta")
        if let meta = try? JSONHelper.loadDictionary(from: metaURL) {
            if let settings = meta.dictionary("grid_settings") {
                return parseIMPMetadataGrid(from: settings, defaultGrid: defaultGrid)
            }
            if let spacing = meta.double("grid_spacing"),
               spacing > 0 {
                return HorizontalGridSettings(
                    name: defaultGrid.name,
                    mode: "square",
                    spacingSquare: spacing,
                    spacingRect: defaultGrid.spacingRect,
                    origin: defaultGrid.origin
                )
            }
        }

        return defaultGrid
    }

    private static func parseCurrentGrid(from json: JSONDictionary, defaultGrid: HorizontalGridSettings) -> HorizontalGridSettings {
        let mode = json.string("mode") ?? defaultGrid.mode
        let origin = json.point("origin") ?? defaultGrid.origin
        let spacingSquare = json.double("spacing_square") ?? defaultGrid.spacingSquare
        let spacingRect = json.point("spacing_rect") ?? defaultGrid.spacingRect

        return HorizontalGridSettings(
            name: json.string("name") ?? defaultGrid.name,
            mode: mode,
            spacingSquare: spacingSquare,
            spacingRect: spacingRect,
            origin: origin
        )
    }

    private static func parseIMPMetadataGrid(from json: JSONDictionary, defaultGrid: HorizontalGridSettings) -> HorizontalGridSettings {
        let mode = json.string("mode") ?? defaultGrid.mode
        let origin = HorizontalPoint(
            x: json.double("origin_x") ?? defaultGrid.origin.x,
            y: json.double("origin_y") ?? defaultGrid.origin.y
        )
        return HorizontalGridSettings(
            name: defaultGrid.name,
            mode: mode,
            spacingSquare: json.double("spacing_square") ?? defaultGrid.spacingSquare,
            spacingRect: HorizontalPoint(
                x: json.double("spacing_x") ?? defaultGrid.spacingRect.x,
                y: json.double("spacing_y") ?? defaultGrid.spacingRect.y
            ),
            origin: origin
        )
    }

    func withClampedValues() -> HorizontalGridSettings {
        HorizontalGridSettings(
            name: name,
            mode: mode,
            spacingSquare: spacingSquare,
            spacingRect: spacingRect,
            origin: origin
        )
    }

    func toggledMode(_ newMode: String) -> HorizontalGridSettings {
        HorizontalGridSettings(
            name: name,
            mode: newMode,
            spacingSquare: spacingSquare,
            spacingRect: spacingRect,
            origin: origin
        )
    }

    private static func sanitizedSpacing(_ spacing: HorizontalPoint, fallback: HorizontalPoint) -> HorizontalPoint {
        HorizontalPoint(
            x: sanitizedSpacing(spacing.x, fallback: fallback.x),
            y: sanitizedSpacing(spacing.y, fallback: fallback.y)
        )
    }

    private static func sanitizedSpacing(_ spacing: Double, fallback: Double) -> Double {
        let value = spacing > 0 ? spacing : fallback
        return min(max(value, minimumSpacing), maximumSpacing)
    }

    private static func clampedOrigin(_ origin: HorizontalPoint) -> HorizontalPoint {
        HorizontalPoint(
            x: min(max(origin.x, minimumOrigin), maximumOrigin),
            y: min(max(origin.y, minimumOrigin), maximumOrigin)
        )
    }
}
