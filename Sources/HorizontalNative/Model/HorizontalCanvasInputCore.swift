import SwiftUI

// Platform-neutral canvas-input logic, extracted verbatim-in-behavior from the
// macOS `TrackpadCanvasMonitor.MonitorView` (InteractiveCanvasView.swift) so it
// can be reused by the cross-platform SwiftUI input layer (and the macOS
// scroll-wheel shim). No AppKit/UIKit: the only platform types are the SwiftUI
// `EventModifiers`/`KeyEquivalent` adapters, which exist on both platforms.
//
// This is the "what does an input MEAN" layer — the drag/tap state machine, the
// modifier→click-action map, and the key→command decoder. The event *capture*
// (NSEvent vs SwiftUI gestures/KeyPress) stays in the per-platform views and
// feeds the neutral types below.

/// The four canvas-relevant modifier keys, independent of NSEvent/UIKey.
struct HorizontalCanvasInputModifiers: OptionSet, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let command = HorizontalCanvasInputModifiers(rawValue: 1 << 0)
    static let option = HorizontalCanvasInputModifiers(rawValue: 1 << 1)
    static let control = HorizontalCanvasInputModifiers(rawValue: 1 << 2)
    static let shift = HorizontalCanvasInputModifiers(rawValue: 1 << 3)

    init(command: Bool, option: Bool, control: Bool, shift: Bool) {
        var value: HorizontalCanvasInputModifiers = []
        if command { value.insert(.command) }
        if option { value.insert(.option) }
        if control { value.insert(.control) }
        if shift { value.insert(.shift) }
        self = value
    }

    /// Adapter for the SwiftUI gesture / `KeyPress` path.
    init(_ eventModifiers: EventModifiers) {
        self.init(
            command: eventModifiers.contains(.command),
            option: eventModifiers.contains(.option),
            control: eventModifiers.contains(.control),
            shift: eventModifiers.contains(.shift)
        )
    }
}

/// A keyboard event reduced to the neutral fields the decoder needs. Built from
/// an `NSEvent` (macOS monitor) or a SwiftUI `KeyPress` (unified layer).
struct HorizontalCanvasKeyEvent {
    /// `charactersIgnoringModifiers`, as-is (not lower-cased).
    var characters: String?
    /// macOS hardware key code (123–126 = arrows, 53 = esc, …). Nil on the
    /// SwiftUI path, which supplies `key` instead.
    var keyCode: UInt16?
    /// SwiftUI key (`.escape`, `.leftArrow`, …). Nil on the macOS path.
    var key: KeyEquivalent?
    var modifiers: HorizontalCanvasInputModifiers

    init(characters: String? = nil, keyCode: UInt16? = nil, key: KeyEquivalent? = nil, modifiers: HorizontalCanvasInputModifiers) {
        self.characters = characters
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }
}

/// The primary (select / area-drag) gesture state machine. Mirrors the former
/// `MonitorView.PrimaryDragState` + `updatePrimaryDrag`/`finishPrimaryDrag`.
struct HorizontalPrimaryDragState {
    var start: CGPoint
    var current: CGPoint
    var points: [CGPoint]
    var action: HorizontalSelectionClickAction
    var clickCount: Int
    var isActive = false

    /// Distance (points) a drag must travel before it becomes an area-selection
    /// instead of a click.
    static let activationThreshold: CGFloat = 10

    /// Extend the drag to a new location, flipping `isActive` once the tool's
    /// activation threshold is crossed (box: both axes; lasso/paint: either).
    mutating func extend(to location: CGPoint, tool: HorizontalSelectionTool) {
        current = location
        points.append(location)
        guard !isActive else { return }
        let distanceX = abs(location.x - start.x)
        let distanceY = abs(location.y - start.y)
        switch tool {
        case .box:
            isActive = distanceX > Self.activationThreshold && distanceY > Self.activationThreshold
        case .lasso, .paint:
            isActive = distanceX > Self.activationThreshold || distanceY > Self.activationThreshold
        }
    }

    enum Resolution {
        case click(point: CGPoint, clickCount: Int, action: HorizontalSelectionClickAction)
        case drag(start: CGPoint, current: CGPoint, points: [CGPoint], action: HorizontalSelectionClickAction)
    }

    /// Finish the drag: an active drag is an area selection, otherwise a click.
    mutating func resolve(at location: CGPoint) -> Resolution {
        current = location
        points.append(location)
        if isActive {
            return .drag(start: start, current: current, points: points, action: action)
        }
        return .click(point: location, clickCount: clickCount, action: action)
    }
}

/// Pure decoders: modifiers→click-action, key→command, key predicates. Static so
/// both the macOS monitor and the SwiftUI layer call the identical logic.
enum HorizontalCanvasInputCore {

    // MARK: - Grid snapping

    /// Snaps a world point onto the grid.
    ///
    /// Requirement: the result is the nearest grid intersection, where the grid
    /// is anchored at `grid.origin` and its spacing is divided by `divisor` (the
    /// fine-grid modifier). Rounding is symmetric about zero — a point exactly
    /// half a step from two intersections rounds away from the origin on both
    /// sides — so dragging left and right across the same boundary snaps
    /// consistently rather than favouring one direction.
    ///
    /// Integer arithmetic throughout: coordinates are nanometres, and a snapped
    /// point has to land exactly on an intersection so that repeated snapping is
    /// idempotent and geometry stays on-grid when written back to the file.
    static func snapToGrid(
        _ point: HorizontalPoint,
        grid: HorizontalGridSettings,
        divisor: Int
    ) -> HorizontalPoint {
        let safeDivisor = max(divisor, 1)
        let originX = Int64(grid.origin.x)
        let originY = Int64(grid.origin.y)
        // A divisor finer than one unit would collapse the grid, so clamp.
        let spacingX = max(Int64(grid.spacing.x) / Int64(safeDivisor), 1)
        let spacingY = max(Int64(grid.spacing.y) / Int64(safeDivisor), 1)
        return HorizontalPoint(
            x: Double(nearestMultiple(of: spacingX, to: Int64(point.x) - originX) + originX),
            y: Double(nearestMultiple(of: spacingY, to: Int64(point.y) - originY) + originY)
        )
    }

    /// Nearest multiple of `multiple` to `value`, rounding halves away from zero.
    private static func nearestMultiple(of multiple: Int64, to value: Int64) -> Int64 {
        guard multiple != 0 else { return value }
        let halfStep = multiple / 2
        let biased = value >= 0 ? value + halfStep : value - halfStep
        return (biased / multiple) * multiple
    }

    /// Ctrl→(user pref), Option→remove, Cmd→toggle, Shift→add, else replace.
    static func clickAction(
        modifiers: HorizontalCanvasInputModifiers,
        modifierAction: HorizontalSelectionModifierAction
    ) -> HorizontalSelectionClickAction {
        if modifiers.contains(.control) { return modifierAction.clickAction }
        if modifiers.contains(.option) { return .remove }
        if modifiers.contains(.command) { return .toggle }
        if modifiers.contains(.shift) { return .add }
        return .replace
    }

    /// default Appearance::GridFineModifier::ALT (Option = 10× fine).
    static func gridDivisor(modifiers: HorizontalCanvasInputModifiers) -> Int {
        modifiers.contains(.option) ? 10 : 1
    }

    static func isEscape(_ event: HorizontalCanvasKeyEvent) -> Bool {
        event.keyCode == 53 || event.characters == "\u{1b}" || matches(event.key, .escape)
    }

    static func isReturn(_ event: HorizontalCanvasKeyEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76 || event.characters == "\r" || matches(event.key, .return)
    }

    static func isDelete(_ event: HorizontalCanvasKeyEvent) -> Bool {
        event.keyCode == 51 || event.keyCode == 117
            || event.characters == "\u{7f}" || event.characters == "\u{8}"
            || matches(event.key, .delete) || matches(event.key, .deleteForward)
    }

    static func arrowDirection(_ event: HorizontalCanvasKeyEvent) -> HorizontalPoint? {
        switch event.keyCode {
        case 123: return HorizontalPoint(x: -1, y: 0)
        case 124: return HorizontalPoint(x: 1, y: 0)
        case 125: return HorizontalPoint(x: 0, y: -1)
        case 126: return HorizontalPoint(x: 0, y: 1)
        default: break
        }
        if matches(event.key, .leftArrow) { return HorizontalPoint(x: -1, y: 0) }
        if matches(event.key, .rightArrow) { return HorizontalPoint(x: 1, y: 0) }
        if matches(event.key, .upArrow) { return HorizontalPoint(x: 0, y: 1) }
        if matches(event.key, .downArrow) { return HorizontalPoint(x: 0, y: -1) }
        return nil
    }

    /// The ~25-key canvas-command table. Mirrors `MonitorView.canvasCommand`.
    /// The digit a key names, independent of modifiers and layout.
    ///
    /// `charactersIgnoringModifiers` still applies Shift on macOS, so ⇧1 arrives
    /// as "!" rather than "1". Match the US shifted row too, and fall back to
    /// the hardware key code, which no layout or modifier can disturb.
    static func digit(_ event: HorizontalCanvasKeyEvent) -> Int? {
        if let characters = event.characters {
            if let value = Int(characters), (1...9).contains(value) {
                return value
            }
            if let index = shiftedDigitRow.firstIndex(of: characters) {
                return index + 1
            }
        }
        if let keyCode = event.keyCode, let value = digitKeyCodes[keyCode] {
            return value
        }
        return nil
    }

    private static let shiftedDigitRow = ["!", "@", "#", "$", "%", "^", "&", "*", "("]

    /// ANSI key codes for the number row, 1 through 9. Note 5 and 6 are 23/22 —
    /// the row is not contiguous.
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    /// Number keys pick the working copper layer: 1 top, 2 bottom, then 3… for
    /// inner 1, 2, 3 in stackup order.
    ///
    /// Bottom is 2 rather than last because it is the layer you reach for most
    /// after top; inner layers follow in order, however many the board has.
    /// Whether the layer exists on the current board is the caller's business —
    /// this decoder never sees a board.
    static func copperLayer(forDigit digit: Int) -> Int? {
        switch digit {
        case 1: return HorizontalBoardLayers.topCopper
        case 2: return HorizontalBoardLayers.bottomCopper
        case 3: return HorizontalBoardLayers.in1Copper
        case 4: return HorizontalBoardLayers.in2Copper
        case 5: return HorizontalBoardLayers.in3Copper
        case 6: return HorizontalBoardLayers.in4Copper
        case 7: return HorizontalBoardLayers.in5Copper
        case 8: return HorizontalBoardLayers.in6Copper
        case 9: return HorizontalBoardLayers.in7Copper
        default: return nil
        }
    }

    /// ⇧1/⇧2 and ⌃1/⌃2 jump to a whole board view: placement or silkscreen for
    /// the top or bottom side. Only the two side digits carry these — there is
    /// no "inner placement" to show.
    static func boardLayerViewPreset(
        forDigit digit: Int,
        modifiers: HorizontalCanvasInputModifiers
    ) -> HorizontalBoardLayerViewPreset? {
        switch (modifiers, digit) {
        case (.shift, 1): return .topPlacement
        case (.shift, 2): return .bottomPlacement
        case (.control, 1): return .topSilkscreen
        case (.control, 2): return .bottomSilkscreen
        default: return nil
        }
    }

    static func command(_ event: HorizontalCanvasKeyEvent, supportsTrackVias: Bool) -> HorizontalCanvasCommand? {
        let modifiers = event.modifiers
        let characters = event.characters?.lowercased()

        if modifiers == .command, characters == "a" {
            return .selectAll
        }
        if modifiers == .shift, characters == "v" {
            return .moveNetSegmentToNewNet
        }
        if modifiers == .shift, characters == "l" {
            // ⇧L: select all copper on the selection's net (cf. L = highlight).
            return .selectNet
        }
        if modifiers == .command {
            // Beat the system Edit-menu Copy/Paste on the canvas; a focused text
            // field keeps its own ⌘C/⌘V/⌘D (handled by the focus model / guard).
            switch characters {
            case "c": return .copySelection
            case "v": return .pasteSelection
            case "d": return .duplicateSelection
            default: break
            }
        }
        if let digit = digit(event),
           let preset = boardLayerViewPreset(forDigit: digit, modifiers: modifiers) {
            return .selectBoardLayerView(preset)
        }

        guard modifiers.isEmpty else {
            return nil
        }

        if let digit = digit(event), let layer = copperLayer(forDigit: digit) {
            return .selectLayer(layer)
        }

        switch characters {
        case "e": return .mirrorSelection
        case "i": return .editSymbolPinNames
        case "c": return .toggleRectanglePlacementMode
        case "l": return .highlightNet
        case "m": return .moveSelection
        case "n": return .drawNetLine
        case "x": return .drawTrack
        case "/": return .flipTrackPosture
        case "w": return .enterTrackWidth
        case "s": return .showToolSettings
        case "r": return .rotateSelection
        case "t": return .twirlSelection
        case "v": return supportsTrackVias ? .toggleVia : .moveNetSegmentToExistingNet
        default: return nil
        }
    }

    static func isSelectAllCommand(_ event: HorizontalCanvasKeyEvent) -> Bool {
        event.modifiers == .command && event.characters?.lowercased() == "a"
    }

    static func isClipboardCommand(_ event: HorizontalCanvasKeyEvent) -> Bool {
        guard event.modifiers == .command else { return false }
        switch event.characters?.lowercased() {
        case "c", "v", "x", "d": return true
        default: return false
        }
    }

    /// Whether a decoded command may fire while the canvas lacks key focus.
    /// Everything except `.highlightNet` (which needs the canvas focused).
    static func allowedWithoutCanvasFocus(_ command: HorizontalCanvasCommand) -> Bool {
        if case .highlightNet = command { return false }
        return true
    }

    private static func matches(_ key: KeyEquivalent?, _ target: KeyEquivalent) -> Bool {
        // Compare by character so this does not depend on KeyEquivalent's
        // Equatable conformance across SDKs.
        key?.character == target.character
    }
}
