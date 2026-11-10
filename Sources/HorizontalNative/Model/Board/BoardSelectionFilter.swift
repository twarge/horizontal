import Foundation

/// A kind of board object, as the board's selection filter offers it
/// (Horizon's Selection Filter).
enum BoardSelectionKind: String, CaseIterable, Identifiable, Hashable {
    case packages
    case tracks
    case vias
    case junctions
    case polygons
    case planes
    case keepouts
    case texts
    case holes
    case lines
    case dimensions
    case decals
    case netTies = "net_ties"
    case connectionLines = "connection_lines"
    case panels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .packages: "Packages"
        case .tracks: "Tracks"
        case .vias: "Vias"
        case .junctions: "Junctions"
        case .polygons: "Polygons"
        case .planes: "Planes"
        case .keepouts: "Keepouts"
        case .texts: "Texts"
        case .holes: "Holes"
        case .lines: "Lines and Arcs"
        case .dimensions: "Dimensions"
        case .decals: "Decals"
        case .netTies: "Net Ties"
        case .connectionLines: "Connection Lines"
        case .panels: "Panels"
        }
    }

    /// The kind a canvas object is of; nil for one that is no board
    /// object (a schematic's), which no board filter keeps out. A package's
    /// pads go with it.
    init?(_ type: HorizontalObjectType) {
        switch type {
        case .boardPackage, .pad: self = .packages
        case .track: self = .tracks
        case .via: self = .vias
        case .junction: self = .junctions
        case .polygonEdge, .polygonVertex, .polygonArcCenter: self = .polygons
        case .plane: self = .planes
        case .keepout: self = .keepouts
        case .text: self = .texts
        case .boardHole: self = .holes
        case .boardLine, .boardArc: self = .lines
        case .dimension: self = .dimensions
        case .boardDecal: self = .decals
        case .boardNetTie: self = .netTies
        case .connectionLine: self = .connectionLines
        case .boardPanel: self = .panels
        case .padstackShape, .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel,
             .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
            return nil
        }
    }
}

/// Which kinds of object a click, a box (lasso, paint) or Select All picks
/// on the board: every kind but those switched off, as Horizon's Selection
/// Filter has it. What is drawn, and what the cursor snaps to, stay as they
/// are; a filtered kind just isn't picked.
struct BoardSelectionFilter: Hashable {
    /// The kinds switched off; empty picks everything.
    var excluded: Set<BoardSelectionKind> = []

    var isFiltering: Bool { !excluded.isEmpty }

    func admits(_ kind: BoardSelectionKind) -> Bool {
        !excluded.contains(kind)
    }

    func admits(_ ref: HorizontalSelectableRef) -> Bool {
        guard !excluded.isEmpty, let kind = BoardSelectionKind(ref.type) else {
            return true
        }
        return !excluded.contains(kind)
    }

    mutating func set(_ kind: BoardSelectionKind, admitted: Bool) {
        if admitted {
            excluded.remove(kind)
        } else {
            excluded.insert(kind)
        }
    }

    /// Only `kind` picked: what a filter is mostly for, a box round a crowded
    /// area that should take its vias alone, say.
    mutating func only(_ kind: BoardSelectionKind) {
        excluded = Set(BoardSelectionKind.allCases).subtracting([kind])
    }
}
