import SwiftUI
import XCTest
@testable import HorizontalNative

/// Pins the platform-neutral `HorizontalCanvasInputCore` (extracted from the macOS
/// `MonitorView`) to the exact behavior it replaced: the modifier→click-action
/// map, the ~25-key command table, the key predicates, and the drag state
/// machine. These run on the macOS test host but exercise zero AppKit — the same
/// logic the unified SwiftUI input layer will call on iOS.
final class HorizontalCanvasInputCoreTests: XCTestCase {

    private typealias Mods = HorizontalCanvasInputModifiers

    /// Stable token for the no-associated-value commands under test
    /// (`HorizontalCanvasCommand` isn't Equatable because other cases carry payloads).
    private func token(_ command: HorizontalCanvasCommand?) -> String? {
        guard let command else { return nil }
        switch command {
        case .selectAll: return "selectAll"
        case .selectNet: return "selectNet"
        case .copySelection: return "copy"
        case .pasteSelection: return "paste"
        case .duplicateSelection: return "duplicate"
        case .moveNetSegmentToNewNet: return "moveNetNew"
        case .moveNetSegmentToExistingNet: return "moveNetExisting"
        case .mirrorSelection: return "mirror"
        case .editSymbolPinNames: return "editPins"
        case .toggleRectanglePlacementMode: return "toggleRect"
        case .highlightNet: return "highlight"
        case .moveSelection: return "move"
        case .drawNetLine: return "drawNet"
        case .drawTrack: return "drawTrack"
        case .flipTrackPosture: return "flip"
        case .enterTrackWidth: return "width"
        case .showToolSettings: return "settings"
        case .rotateSelection: return "rotate"
        case .twirlSelection: return "twirl"
        case .toggleVia: return "via"
        default: return "other"
        }
    }

    private func key(_ characters: String?, _ modifiers: Mods = []) -> HorizontalCanvasKeyEvent {
        HorizontalCanvasKeyEvent(characters: characters, modifiers: modifiers)
    }

    // MARK: - Modifier → click action (priority: ctrl > option > cmd > shift)

    func testClickActionMapping() {
        XCTAssertEqual(HorizontalCanvasInputCore.clickAction(modifiers: [], modifierAction: .toggle), .replace)
        XCTAssertEqual(HorizontalCanvasInputCore.clickAction(modifiers: .shift, modifierAction: .toggle), .add)
        XCTAssertEqual(HorizontalCanvasInputCore.clickAction(modifiers: .command, modifierAction: .toggle), .toggle)
        XCTAssertEqual(HorizontalCanvasInputCore.clickAction(modifiers: .option, modifierAction: .toggle), .remove)
        // Control wins and defers to the user's configured modifier action.
        XCTAssertEqual(HorizontalCanvasInputCore.clickAction(modifiers: .control, modifierAction: .add), .add)
        XCTAssertEqual(HorizontalCanvasInputCore.clickAction(modifiers: [.control, .shift], modifierAction: .remove), .remove)
        // Priority: option beats command beats shift.
        XCTAssertEqual(HorizontalCanvasInputCore.clickAction(modifiers: [.option, .command, .shift], modifierAction: .toggle), .remove)
    }

    func testEventModifiersAdapter() {
        XCTAssertEqual(Mods(EventModifiers([.command, .shift])), [.command, .shift])
        XCTAssertEqual(Mods(EventModifiers()), [])
    }

    // MARK: - Grid divisor

    func testGridDivisor() {
        XCTAssertEqual(HorizontalCanvasInputCore.gridDivisor(modifiers: []), 1)
        XCTAssertEqual(HorizontalCanvasInputCore.gridDivisor(modifiers: .option), 10)
        XCTAssertEqual(HorizontalCanvasInputCore.gridDivisor(modifiers: .command), 1)
    }

    // MARK: - Command table

    func testCommandModifierKeys() {
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("a", .command), supportsTrackVias: true)), "selectAll")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("v", .shift), supportsTrackVias: true)), "moveNetNew")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("l", .shift), supportsTrackVias: true)), "selectNet")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("c", .command), supportsTrackVias: true)), "copy")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("v", .command), supportsTrackVias: true)), "paste")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("d", .command), supportsTrackVias: true)), "duplicate")
    }

    func testCommandUnmodifiedKeys() {
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("e"), supportsTrackVias: true)), "mirror")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("m"), supportsTrackVias: true)), "move")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("r"), supportsTrackVias: true)), "rotate")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("t"), supportsTrackVias: true)), "twirl")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("n"), supportsTrackVias: true)), "drawNet")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("x"), supportsTrackVias: true)), "drawTrack")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("l"), supportsTrackVias: true)), "highlight")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("i"), supportsTrackVias: true)), "editPins")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("c"), supportsTrackVias: true)), "toggleRect")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("/"), supportsTrackVias: true)), "flip")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("w"), supportsTrackVias: true)), "width")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("s"), supportsTrackVias: true)), "settings")
        // Case-insensitive (charactersIgnoringModifiers can be upper-case).
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("R"), supportsTrackVias: true)), "rotate")
    }

    func testCommandViaDependsOnTrackViaSupport() {
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("v"), supportsTrackVias: true)), "via")
        XCTAssertEqual(token(HorizontalCanvasInputCore.command(key("v"), supportsTrackVias: false)), "moveNetExisting")
    }

    func testCommandRejectsExtraModifiers() {
        // A bare-key command requires an empty modifier set.
        XCTAssertNil(HorizontalCanvasInputCore.command(key("m", .command), supportsTrackVias: true))
        XCTAssertNil(HorizontalCanvasInputCore.command(key("a", [.command, .shift]), supportsTrackVias: true))
        XCTAssertNil(HorizontalCanvasInputCore.command(key("z"), supportsTrackVias: true))
    }

    func testClipboardAndSelectAllPredicates() {
        XCTAssertTrue(HorizontalCanvasInputCore.isSelectAllCommand(key("a", .command)))
        XCTAssertFalse(HorizontalCanvasInputCore.isSelectAllCommand(key("a")))
        for c in ["c", "v", "x", "d"] {
            XCTAssertTrue(HorizontalCanvasInputCore.isClipboardCommand(key(c, .command)), "\(c)")
        }
        XCTAssertFalse(HorizontalCanvasInputCore.isClipboardCommand(key("a", .command)))
        XCTAssertFalse(HorizontalCanvasInputCore.isClipboardCommand(key("c")))
    }

    func testAllowedWithoutCanvasFocus() {
        XCTAssertFalse(HorizontalCanvasInputCore.allowedWithoutCanvasFocus(.highlightNet))
        XCTAssertTrue(HorizontalCanvasInputCore.allowedWithoutCanvasFocus(.rotateSelection))
        XCTAssertTrue(HorizontalCanvasInputCore.allowedWithoutCanvasFocus(.deleteSelection))
    }

    // MARK: - Key predicates (keyCode + characters + KeyEquivalent)

    func testEscapeReturnDelete() {
        XCTAssertTrue(HorizontalCanvasInputCore.isEscape(HorizontalCanvasKeyEvent(keyCode: 53, modifiers: [])))
        XCTAssertTrue(HorizontalCanvasInputCore.isEscape(HorizontalCanvasKeyEvent(characters: "\u{1b}", modifiers: [])))
        XCTAssertTrue(HorizontalCanvasInputCore.isEscape(HorizontalCanvasKeyEvent(key: .escape, modifiers: [])))

        XCTAssertTrue(HorizontalCanvasInputCore.isReturn(HorizontalCanvasKeyEvent(keyCode: 36, modifiers: [])))
        XCTAssertTrue(HorizontalCanvasInputCore.isReturn(HorizontalCanvasKeyEvent(keyCode: 76, modifiers: [])))
        XCTAssertTrue(HorizontalCanvasInputCore.isReturn(HorizontalCanvasKeyEvent(key: .return, modifiers: [])))

        XCTAssertTrue(HorizontalCanvasInputCore.isDelete(HorizontalCanvasKeyEvent(keyCode: 51, modifiers: [])))
        XCTAssertTrue(HorizontalCanvasInputCore.isDelete(HorizontalCanvasKeyEvent(keyCode: 117, modifiers: [])))
        XCTAssertTrue(HorizontalCanvasInputCore.isDelete(HorizontalCanvasKeyEvent(key: .delete, modifiers: [])))

        XCTAssertFalse(HorizontalCanvasInputCore.isEscape(key("a")))
        XCTAssertFalse(HorizontalCanvasInputCore.isReturn(key("a")))
        XCTAssertFalse(HorizontalCanvasInputCore.isDelete(key("a")))
    }

    func testArrowDirection() {
        XCTAssertEqual(HorizontalCanvasInputCore.arrowDirection(HorizontalCanvasKeyEvent(keyCode: 123, modifiers: [])), HorizontalPoint(x: -1, y: 0))
        XCTAssertEqual(HorizontalCanvasInputCore.arrowDirection(HorizontalCanvasKeyEvent(keyCode: 124, modifiers: [])), HorizontalPoint(x: 1, y: 0))
        XCTAssertEqual(HorizontalCanvasInputCore.arrowDirection(HorizontalCanvasKeyEvent(keyCode: 125, modifiers: [])), HorizontalPoint(x: 0, y: -1))
        XCTAssertEqual(HorizontalCanvasInputCore.arrowDirection(HorizontalCanvasKeyEvent(keyCode: 126, modifiers: [])), HorizontalPoint(x: 0, y: 1))
        // SwiftUI KeyEquivalent fallback (the unified layer's path). Note up = +y.
        XCTAssertEqual(HorizontalCanvasInputCore.arrowDirection(HorizontalCanvasKeyEvent(key: .leftArrow, modifiers: [])), HorizontalPoint(x: -1, y: 0))
        XCTAssertEqual(HorizontalCanvasInputCore.arrowDirection(HorizontalCanvasKeyEvent(key: .upArrow, modifiers: [])), HorizontalPoint(x: 0, y: 1))
        XCTAssertEqual(HorizontalCanvasInputCore.arrowDirection(HorizontalCanvasKeyEvent(key: .downArrow, modifiers: [])), HorizontalPoint(x: 0, y: -1))
        XCTAssertNil(HorizontalCanvasInputCore.arrowDirection(key("a")))
    }

    // MARK: - Primary drag state machine

    private func makeDrag() -> HorizontalPrimaryDragState {
        HorizontalPrimaryDragState(start: .zero, current: .zero, points: [.zero], action: .replace, clickCount: 1)
    }

    func testDragStaysClickBelowThreshold() {
        var state = makeDrag()
        state.extend(to: CGPoint(x: 5, y: 5), tool: .box)
        XCTAssertFalse(state.isActive)
        guard case let .click(point, clickCount, action) = state.resolve(at: CGPoint(x: 6, y: 6)) else {
            return XCTFail("expected a click")
        }
        XCTAssertEqual(point, CGPoint(x: 6, y: 6))
        XCTAssertEqual(clickCount, 1)
        XCTAssertEqual(action, .replace)
    }

    func testBoxToolNeedsBothAxes() {
        var onlyX = makeDrag()
        onlyX.extend(to: CGPoint(x: 40, y: 3), tool: .box)
        XCTAssertFalse(onlyX.isActive, "box needs BOTH axes > 10")

        var both = makeDrag()
        both.extend(to: CGPoint(x: 40, y: 40), tool: .box)
        XCTAssertTrue(both.isActive)
        guard case .drag = both.resolve(at: CGPoint(x: 41, y: 41)) else {
            return XCTFail("expected a drag")
        }
    }

    func testLassoToolNeedsEitherAxis() {
        var onlyX = makeDrag()
        onlyX.extend(to: CGPoint(x: 40, y: 1), tool: .lasso)
        XCTAssertTrue(onlyX.isActive, "lasso activates on EITHER axis > 10")
    }
}
