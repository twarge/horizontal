import Foundation
import XCTest
@testable import HorizontalNative

/// Every build starts read-only, and anyone can turn it off, warned first
/// that editing is in beta and a risk to their data.
final class HorizontalReadOnlyBuildTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "horizontal-readonly-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testUnsetPreferenceIsReadOnlyOnEveryConfiguration() throws {
        // Read-only is the safe default everywhere, so a fresh install never
        // starts out able to overwrite a project.
        let defaults = try isolatedDefaults()
        defaults.removeObject(forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        XCTAssertTrue(HorizontalOperationDefaults.readOnlyOperation(defaults: defaults))
        XCTAssertTrue(HorizontalAppearanceSettings(defaults: defaults).isReadOnlyOperationEnabled)
    }

    @MainActor
    func testTurningItOffIsHonouredInEveryBuild() throws {
        let defaults = try isolatedDefaults()
        let settings = HorizontalAppearanceSettings(defaults: defaults)
        settings.readOnlyOperationBinding().wrappedValue = false
        XCTAssertFalse(settings.isReadOnlyOperationEnabled)
        XCTAssertFalse(HorizontalOperationDefaults.readOnlyOperation(defaults: defaults), "and it stays off on the next launch")
    }

    func testUnlockingWarnsThatEditingIsBetaAndRisksData() {
        let warning = HorizontalOperationDefaults.editingBetaWarning
        XCTAssertTrue(warning.contains("beta"), warning)
        XCTAssertTrue(warning.contains("risk to your data"), warning)
        XCTAssertTrue(warning.contains("backup"), warning)
    }

    // The document's write guard itself isn't reachable from a test:
    // FileDocumentWriteConfiguration has no public initializer. It is a single
    // `guard !HorizontalOperationDefaults.readOnlyOperation()` on the same flag
    // covered above.

    func testRefusalMessageSaysWhereToTurnItOff() {
        let message = HorizontalProjectDocumentError.readOnlyOperation.errorDescription ?? ""
        XCTAssertTrue(message.contains("Settings"), message)
    }
}

/// What the lock actually withholds.
///
/// The tool rails now omit the editing tools rather than dimming them, which
/// is a view-layer change no harness here can see. What it reflects, and what
/// this guards, is the gate underneath: with the lock on, the canvas offers no
/// capability that would change the design — so nothing the rails could show
/// would work anyway, and a command arriving from a menu or a key does
/// nothing.
final class HorizontalReadOnlyCanvasCommandTests: XCTestCase {
    /// Every handler wired, so the only thing deciding the answer is the lock.
    private func handlers(isReadOnly: Bool) -> HorizontalCanvasCommandHandlerSet {
        var set = HorizontalCanvasCommandHandlerSet(
            isReadOnly: isReadOnly,
            hasInteraction: false,
            selectAll: {},
            deleteSelection: {},
            highlightSelection: {},
            beginMove: {},
            rotateSelection: {},
            mirrorSelection: {},
            moveSelectionBy: { _ in },
            commitInteraction: {},
            cancelInteraction: {}
        )
        set.drawNetLine = {}
        set.drawTrack = {}
        set.drawGraphics = { (_: HorizontalDrawingPrimitive) in }
        set.drawPlane = {}
        set.drawDimension = {}
        set.addText = {}
        set.placePowerSymbol = {}
        set.placeBusLabel = {}
        set.placeBusRipper = {}
        set.tieNets = {}
        set.placePad = {}
        set.placeHole = { (_: HorizontalHoleShape) in }
        set.updateAllPlanes = {}
        set.roundOffVertex = {}
        set.copySelection = {}
        set.pasteSelection = {}
        set.duplicateSelection = {}
        return set
    }

    func testTheLockWithholdsEveryEditingCapability() {
        let locked = handlers(isReadOnly: true).actions()
        let editing: [(String, Bool)] = [
            ("delete", locked.canDeleteSelection), ("move", locked.canMoveSelection),
            ("rotate", locked.canRotateSelection), ("mirror", locked.canMirrorSelection),
            ("net line", locked.canDrawNetLine), ("track", locked.canDrawTrack),
            ("graphics", locked.canDrawGraphics), ("plane", locked.canDrawPlane),
            ("dimension", locked.canDrawDimension), ("text", locked.canAddText),
            ("power symbol", locked.canPlacePowerSymbol), ("bus label", locked.canPlaceBusLabel),
            ("bus ripper", locked.canPlaceBusRipper), ("tie nets", locked.canTieNets),
            ("pad", locked.canPlacePad), ("hole", locked.canPlaceHole),
            ("pour", locked.canUpdateAllPlanes), ("round off", locked.canRoundOffVertex),
            ("paste", locked.canPasteSelection), ("duplicate", locked.canDuplicateSelection),
        ]
        for (name, offered) in editing {
            XCTAssertFalse(offered, "a locked document still offers \(name)")
        }
    }

    /// The same set unlocked, so the test above is measuring the lock rather
    /// than a handler nobody wired.
    func testTheSameHandlersAreOfferedWhenUnlocked() {
        let open = handlers(isReadOnly: false).actions()
        XCTAssertTrue(open.canDrawNetLine)
        XCTAssertTrue(open.canDrawTrack)
        XCTAssertTrue(open.canDrawDimension)
        XCTAssertTrue(open.canAddText)
        XCTAssertTrue(open.canPlaceBusLabel)
        XCTAssertTrue(open.canPlaceBusRipper)
        XCTAssertTrue(open.canTieNets)
        XCTAssertTrue(open.canPlacePowerSymbol)
        XCTAssertTrue(open.canUpdateAllPlanes)
        XCTAssertTrue(open.canDeleteSelection)
    }

    /// Reading is not editing: selection, highlighting and framing stay, which
    /// is why those rail buttons stay too.
    func testReadingStaysAvailableWhenLocked() {
        let locked = handlers(isReadOnly: true).actions()
        XCTAssertTrue(locked.canSelectAll)
        XCTAssertTrue(locked.canHighlightNet)
        XCTAssertTrue(locked.canCopySelection)
    }
}
