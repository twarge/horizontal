import Foundation

/// What the schematic canvas is editing: a project sheet, or one of the pool
/// item kinds Horizon edits with its schematic-flavoured "imp" — a symbol or
/// a frame. Each pool mode fixes which tools apply and what the canvas
/// treats as an object, mirroring `imp_symbol` and `imp_frame`.
enum HorizontalSchematicEditorMode: Hashable {
    case sheet
    case symbol
    case frame
}

struct HorizontalSchematicEditorProfile: Hashable {
    var mode: HorizontalSchematicEditorMode
    /// Nets exist: net lines, net segment tools, pin-name editing, part
    /// placement. A pool item has none of these.
    var hasNetTools: Bool
    /// Pins are first-class objects placed from the unplaced column.
    var supportsPins: Bool
    /// The polygon tool makes a real polygon rather than a closed line loop.
    var supportsPolygons: Bool
    /// Junctions draw as crosses whether or not anything attaches to them.
    var showsJunctionsAlways: Bool
    /// Horizon's fixed symbol grid (1.25 mm); nil keeps the sheet's own.
    var gridSpacing: Double?

    var isPoolMode: Bool {
        mode != .sheet
    }

    static let sheet = HorizontalSchematicEditorProfile(
        mode: .sheet,
        hasNetTools: true,
        supportsPins: false,
        supportsPolygons: false,
        showsJunctionsAlways: false,
        gridSpacing: nil
    )

    static let symbol = HorizontalSchematicEditorProfile(
        mode: .symbol,
        hasNetTools: false,
        supportsPins: true,
        supportsPolygons: true,
        showsJunctionsAlways: false,
        gridSpacing: 1_250_000
    )

    static let frame = HorizontalSchematicEditorProfile(
        mode: .frame,
        hasNetTools: false,
        supportsPins: false,
        supportsPolygons: true,
        showsJunctionsAlways: true,
        gridSpacing: 1_250_000
    )

    static func profile(for mode: HorizontalSchematicEditorMode) -> HorizontalSchematicEditorProfile {
        switch mode {
        case .sheet: .sheet
        case .symbol: .symbol
        case .frame: .frame
        }
    }
}

/// `Symbol::PinDisplayMode`: which of a pin's names the editor draws.
enum HorizontalSymbolEditorPinDisplayMode: String, CaseIterable, Hashable {
    case primary
    case alternate
    case both

    var displayName: String {
        switch self {
        case .primary: "Primary"
        case .alternate: "Alternate"
        case .both: "Both"
        }
    }

    /// The sheet loader's `pin_display_mode` spelling for the same choice.
    var schematicMode: String {
        switch self {
        case .primary: "selected_only"
        case .alternate: "alt_only"
        case .both: "all"
        }
    }
}

/// One of the eight orientations a placed symbol can take (`0n`, `90m`…),
/// for which a symbol may carry its own text placements.
struct HorizontalSymbolTextPlacementView: Hashable, Identifiable {
    var angleDegrees: Int
    var mirrored: Bool

    var id: String { key }

    /// The `text_placements` key the schematic loader looks up.
    var key: String {
        "\(angleDegrees)\(mirrored ? "m" : "n")"
    }

    var transform: HorizontalPlacementTransform {
        HorizontalPlacementTransform(shift: .zero, angle: angleDegrees * 65_536 / 360, mirrored: mirrored)
    }

    var displayName: String {
        "\(angleDegrees)°" + (mirrored ? " mirrored" : "")
    }

    static let all: [HorizontalSymbolTextPlacementView] = [false, true].flatMap { mirrored in
        [0, 90, 180, 270].map { HorizontalSymbolTextPlacementView(angleDegrees: $0, mirrored: mirrored) }
    }
}

/// What the symbol editor needs beyond the symbol itself: the unit the pin
/// names come from and the view choices that change how pins bake.
struct HorizontalSymbolEditorContext: Hashable {
    var symbolID: String
    var unitID: String?
    var unitJSON: HorizontalPreservedJSON?
    var poolURL: URL
    var pinDisplayMode: HorizontalSymbolEditorPinDisplayMode = .primary
    /// Horizon's "junctions and hidden names": draw every junction and the
    /// name / pad texts of pins that hide them, greyed.
    var showsJunctionsAndHiddenNames = false
    /// When set, the canvas shows the symbol as placed in that orientation
    /// and edits only its texts' placements for it (Horizon's text placement
    /// preview); nil is the ordinary editor.
    var view: HorizontalSymbolTextPlacementView?
}

extension HorizontalPinOrientation {
    /// The orientation after a quarter turn; clockwise when `clockwise`.
    func rotated(clockwise: Bool) -> HorizontalPinOrientation {
        switch self {
        case .up: clockwise ? .right : .left
        case .down: clockwise ? .left : .right
        case .left: clockwise ? .up : .down
        case .right: clockwise ? .down : .up
        }
    }

    /// Mirrored about a vertical axis, as Horizon's pin mirror does.
    var mirrored: HorizontalPinOrientation {
        switch self {
        case .left: .right
        case .right: .left
        case .up, .down: self
        }
    }
}
