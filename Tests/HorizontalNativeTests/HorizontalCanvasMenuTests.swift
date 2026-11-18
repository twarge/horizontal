import XCTest
@testable import HorizontalNative

/// A right-click on empty canvas shows the canvas's own menu: Paste, which
/// says when there is nothing to paste, Select All, and the tools the canvas
/// has. There used to be no menu there at all.
final class HorizontalCanvasMenuTests: XCTestCase {
    /// What a canvas can do, as its handler set reports it.
    private func actions(_ configure: (inout HorizontalCanvasCommandActions) -> Void = { _ in }) -> HorizontalCanvasCommandActions {
        var actions = HorizontalCanvasCommandActions(
            canDeleteSelection: true, canMoveSelection: true, canRotateSelection: true, canMirrorSelection: true,
            canDrawNetLine: false, canMoveNetSegmentToExistingNet: false, canMoveNetSegmentToNewNet: false,
            canEditSymbolPinNames: false, canHighlightNet: true, canSelectAll: true,
            canCommitInteraction: false, canCancelInteraction: false, dispatch: { _ in }
        )
        configure(&actions)
        return actions
    }

    /// The menu as it reads: titles, `-` for a separator, `(reason)` after a
    /// dimmed item, a submenu's items in brackets.
    private func titles(_ entries: [HorizontalTargetItemMenuEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .separator: "-"
            case .command(let title, _), .select(let title), .toggle(let title, _, _), .action(let title, _), .todo(let title),
                 .choice(let title, _, _, _, _): title
            case .unavailable(let title, let reason): "\(title) (\(reason))"
            case .submenu(let title, let children): "\(title) [\(titles(children).joined(separator: ", "))]"
            }
        }
    }

    private func command(_ title: String, in entries: [HorizontalTargetItemMenuEntry]) -> String? {
        for entry in entries {
            if case .command(title, let command) = entry {
                return String(describing: command)
            }
        }
        return nil
    }

    func testASchematicSheetOffersPasteSelectAllAndItsTools() {
        let sheet = actions {
            $0.canPasteSelection = true
            $0.canDrawNetLine = true
            $0.canPlaceNetLabel = true
            $0.canPlacePowerSymbol = true
            $0.canPlaceBusLabel = true
            $0.canAddText = true
            $0.canDrawGraphics = true
        }
        let entries = HorizontalCanvasMenu.entries(for: sheet, pasteUnavailableReason: nil)
        XCTAssertEqual(titles(entries), [
            "Paste", "Select All", "-",
            "Draw Net Line", "Place Net Label", "Place Power Symbol…", "Place Bus Label…", "-",
            "Add Text…", "Draw [Line, Line Rectangle, Line Circle, Arc, Polygon, Polygon Rectangle, Polygon Circle]",
        ])
        XCTAssertEqual(command("Paste", in: entries), "pasteSelection")
        XCTAssertEqual(command("Select All", in: entries), "selectAll")
        XCTAssertEqual(command("Draw Net Line", in: entries), "drawNetLine")
    }

    func testPasteSaysWhenTheClipboardHoldsNothingToPaste() {
        let sheet = actions { $0.canPasteSelection = true }
        let entries = HorizontalCanvasMenu.entries(for: sheet, pasteUnavailableReason: "Nothing copied from a schematic is on the clipboard.")
        XCTAssertEqual(titles(entries), ["Paste (Nothing copied from a schematic is on the clipboard.)", "Select All"])
        XCTAssertNil(command("Paste", in: entries), "dimmed, it runs nothing")
    }

    /// Locked, the canvas pastes nothing and has no tools: nothing is dimmed
    /// in their place, as the tool rail shows a locked document no tools.
    func testALockedDocumentsMenuIsSelectAllAlone() {
        let entries = HorizontalCanvasMenu.entries(for: actions(), pasteUnavailableReason: "Nothing copied from a schematic is on the clipboard.")
        XCTAssertEqual(titles(entries), ["Select All"])
    }

    func testABoardOffersItsCopperAndDrawingTools() {
        let board = actions {
            $0.canPasteSelection = true
            $0.canDrawTrack = true
            $0.canPlaceVia = true
            $0.canPlaceBoardHole = true
            $0.canAddText = true
            $0.canDrawPlane = true
            $0.canDrawDimension = true
            $0.canPlaceDecal = true
            $0.canMeasureDistance = true
            $0.canUpdateAllPlanes = true
        }
        let entries = HorizontalCanvasMenu.entries(for: board, pasteUnavailableReason: nil)
        XCTAssertEqual(titles(entries), [
            "Paste", "Select All", "-",
            "Draw Track", "Place Via…", "Place Board Hole…", "-",
            "Add Text…", "Draw Plane", "Draw Dimension", "Place Decal…", "-",
            "Measure Distance", "Update All Planes",
        ])
    }

    /// A symbol editor's P places a pin and reaches it as the board's Place
    /// Pad: there the menu names the pin, once.
    func testASymbolEditorPlacesPinsNotPads() {
        let symbol = actions {
            $0.canPlacePad = true
            $0.canPlacePin = true
            $0.canPlaceRefdesAndValue = true
            $0.canPlaceDot = true
        }
        XCTAssertEqual(titles(HorizontalCanvasMenu.entries(for: symbol, pasteUnavailableReason: nil)),
                       ["Select All", "-", "Place Pin", "Place Reference and Value", "Place Dot"])
        let padstack = actions {
            $0.canPlaceShape = true
            $0.canPlaceHole = true
        }
        XCTAssertEqual(titles(HorizontalCanvasMenu.entries(for: padstack, pasteUnavailableReason: nil)),
                       ["Select All", "-", "Place Shape [Circle, Rectangle, Obround]", "Place Hole [Round, Slot]"])
        let package = actions { $0.canPlacePad = true }
        XCTAssertEqual(titles(HorizontalCanvasMenu.entries(for: package, pasteUnavailableReason: nil)),
                       ["Select All", "-", "Place Pad…"])
    }
}
