import XCTest
@testable import HorizontalNative

/// Planes are not independently toggleable: a plane belongs to a copper layer,
/// so it is shown whenever that layer is. What the user controls is the plane
/// FILL — Q recomputes it, Shift-Q clears it — which is board data.
///
/// Two regressions, in sequence, both of which hid a board's pour:
///  1. The Top/Bottom Place presets set `planes = false`, so choosing a
///     placement preset hid the pour with no way back except another preset.
///  2. Removing those assignments left the flag STORED and still decoded from
///     saved settings, with nothing left to set it true and no menu item to
///     reach — so anyone whose settings already held `false` lost their planes
///     permanently, across launches.
///
/// The fix for (2) was to delete the flag rather than to stop writing it: a
/// persisted switch that nothing can turn back on is the bug, whatever its
/// default. These tests pin that there is no such switch to get stuck.
final class BoardPlaneVisibilityTests: XCTestCase {
    /// Settings saved while the flag still existed must not hide anything now.
    /// This is the exact stale state that reached a real user.
    func testSavedSettingsHoldingPlanesFalseCannotHidePlanes() throws {
        let legacy = Data(#"{"topCopper":true,"bottomCopper":true,"planes":false}"#.utf8)
        let options = try JSONDecoder().decode(BoardDisplayOptions.self, from: legacy)

        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topCopper))
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.bottomCopper))
    }

    /// Round-tripping must not reintroduce the key, or a future decoder could
    /// start honouring it again.
    func testPlaneVisibilityIsNotPersisted() throws {
        let encoded = try JSONEncoder().encode(BoardDisplayOptions())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNil(object["planes"], "plane visibility must not be a stored setting")
    }

    /// A plane is visible exactly when its copper layer is — that is the whole
    /// control surface.
    func testPlaneFollowsItsCopperLayer() {
        var options = BoardDisplayOptions()
        options.topPlacementView()

        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.topCopper))
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.bottomCopper))

        options.bottomPlacementView()
        XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.bottomCopper))
        XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.topCopper))
    }

    /// Presets that show a side's copper show that side's pour with it, because
    /// a plane is gated by nothing except its layer.
    func testCopperPresetsShowTheirOwnSidesPour() {
        let top = HorizontalBoardLayers.topCopper
        let bottom = HorizontalBoardLayers.bottomCopper
        let presets: [(String, (inout BoardDisplayOptions) -> Void, Int)] = [
            ("topPlacement", { $0.topPlacementView() }, top),
            ("bottomPlacement", { $0.bottomPlacementView() }, bottom),
            ("topRouting", { $0.topRoutingView() }, top),
            ("bottomRouting", { $0.bottomRoutingView() }, bottom),
        ]

        for (name, apply, side) in presets {
            var options = BoardDisplayOptions()
            apply(&options)
            XCTAssertTrue(options.isLayerVisible(side), "\(name) must show its own side's copper")
        }
    }

    /// The silkscreen views deliberately show no copper — they are mask, silk
    /// and outline — so they show no pour either. That is the rule working, not
    /// a plane being hidden by a switch of its own.
    func testSilkscreenPresetsShowNoCopperAndThereforeNoPour() {
        for apply in [{ (o: inout BoardDisplayOptions) in o.topSilkscreenView() },
                      { (o: inout BoardDisplayOptions) in o.bottomSilkscreenView() }] {
            var options = BoardDisplayOptions()
            apply(&options)
            XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.topCopper))
            XCTAssertFalse(options.isLayerVisible(HorizontalBoardLayers.bottomCopper))
            XCTAssertTrue(options.isLayerVisible(HorizontalBoardLayers.outline))
        }
    }
}
