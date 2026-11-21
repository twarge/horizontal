import Foundation

/// The menu a right-click on empty canvas shows: what the canvas itself can
/// do there, where a right-click on an object shows that object's menu.
///
/// Paste comes first, and is there whenever the canvas pastes at all. With
/// nothing on the clipboard it could take, the item is dimmed and says so,
/// so the menu answers whether a Paste would do anything. Then Select All,
/// and the tools that put something new down, named as the Design menu
/// names them. A tool the canvas doesn't have is left out rather than
/// dimmed: a locked document's menu is Select All alone, and a symbol
/// editor's has no nets.
enum HorizontalCanvasMenu {
    /// `pasteUnavailableReason` is why a Paste would do nothing now, nil when
    /// the clipboard holds something this canvas pastes.
    static func entries(
        for actions: HorizontalCanvasCommandActions,
        pasteUnavailableReason: String?
    ) -> [HorizontalTargetItemMenuEntry] {
        var edit = [HorizontalTargetItemMenuEntry]()
        if actions.canPasteSelection {
            if let pasteUnavailableReason {
                edit.append(.unavailable(title: "Paste", reason: pasteUnavailableReason))
            } else {
                edit.append(.command(title: "Paste", .pasteSelection))
            }
        }
        if actions.canSelectAll {
            edit.append(.command(title: "Select All", .selectAll))
        }

        // What connects: the schematic's wires and names, the board's copper.
        var connect = [HorizontalTargetItemMenuEntry]()
        if actions.canDrawNetLine { connect.append(.command(title: "Draw Net Line", .drawNetLine)) }
        if actions.canPlaceNetLabel { connect.append(.command(title: "Place Net Label", .placeNetLabel)) }
        if actions.canPlacePowerSymbol { connect.append(.command(title: "Place Power Symbol…", .placePowerSymbol)) }
        if actions.canPlaceBusLabel { connect.append(.command(title: "Place Bus Label…", .placeBusLabel)) }
        if actions.canPlaceBusRipper { connect.append(.command(title: "Place Bus Ripper…", .placeBusRipper)) }
        if actions.canDrawTrack { connect.append(.command(title: "Draw Track", .drawTrack)) }
        if actions.canPlaceVia { connect.append(.command(title: "Place Via…", .placeVia)) }
        if actions.canPlaceBoardHole { connect.append(.command(title: "Place Board Hole…", .placeBoardHole)) }
        if actions.canLetViasFollowTracks { connect.append(.command(title: "Let Vias Follow Their Tracks…", .letViasFollowTracks)) }

        // The pool editors' own. A symbol editor's P places a pin, and reaches
        // it as the board's Place Pad, so there the pad is the pin.
        var pool = [HorizontalTargetItemMenuEntry]()
        if actions.canPlacePin {
            pool.append(.command(title: "Place Pin", .placePin))
        } else if actions.canPlacePad {
            pool.append(.command(title: "Place Pad…", .placePad))
        }
        if actions.canPlaceShape {
            pool.append(.submenu(title: "Place Shape", HorizontalPadstackShapeForm.allCases.map {
                .command(title: $0.displayName, .placeShape($0))
            }))
        }
        if actions.canPlaceHole {
            pool.append(.submenu(title: "Place Hole", [
                .command(title: "Round", .placeHole(.round)),
                .command(title: "Slot", .placeHole(.slot)),
            ]))
        }
        if actions.canPlaceRefdesAndValue { pool.append(.command(title: "Place Reference and Value", .placeRefdesAndValue)) }
        if actions.canPlaceDot { pool.append(.command(title: "Place Dot", .placeDot)) }

        var draw = [HorizontalTargetItemMenuEntry]()
        if actions.canAddText { draw.append(.command(title: "Add Text…", .addText)) }
        if actions.canDrawGraphics {
            draw.append(.submenu(title: "Draw", HorizontalDrawingPrimitive.allCases.map {
                .command(title: $0.title, .drawGraphics($0))
            }))
        }
        if actions.canDrawPlane { draw.append(.command(title: "Draw Plane", .drawPlane)) }
        if actions.canDrawDimension { draw.append(.command(title: "Draw Dimension", .drawDimension)) }
        if actions.canPlaceDecal { draw.append(.command(title: "Place Decal…", .placeDecal)) }

        var board = [HorizontalTargetItemMenuEntry]()
        if actions.canMeasureDistance { board.append(.command(title: "Measure Distance", .measureDistance)) }
        if actions.canUpdateAllPlanes { board.append(.command(title: "Update All Planes", .updateAllPlanes)) }

        return Array([edit, connect, pool, draw, board].filter { !$0.isEmpty }.joined(separator: [.separator]))
    }
}
