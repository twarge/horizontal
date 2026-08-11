import XCTest
@testable import HorizontalNative

/// First tests against the executable target's internals via `@testable import`.
/// If this compiles and runs, the whole domain model is unit-testable without a
/// separate library — the rules engine, spatial index, parameter programs, etc.
final class HorizontalBoardRulesModelTests: XCTestCase {
    func testPatchTypeOrderMatchesReference() {
        // Mirrors common.hpp ordering exactly.
        XCTAssertEqual(HorizontalPatchType.other.rawValue, 0)
        XCTAssertEqual(HorizontalPatchType.plane.rawValue, 5)
        XCTAssertEqual(HorizontalPatchType.netTie.rawValue, 10)
        XCTAssertEqual(HorizontalPatchType.count, 11)
        XCTAssertEqual(HorizontalPatchType(jsonString: "hole_npth"), .holeNPTH)
        XCTAssertEqual(HorizontalPatchType(jsonString: "board_edge"), .boardEdge)
    }

    func testDefaultClearancesMatchReferenceFallbacks() {
        let rules = HorizontalBoardRules(rules: nil, netDetails: [:])
        // copper-copper fallback: 0.1mm everywhere.
        XCTAssertEqual(rules.clearanceCopper(net1: "a", net2: "b", layer: 0).clearance(.track, .plane), 100_000)
        // copper-other fallback: 0.1mm.
        XCTAssertEqual(rules.clearanceCopperOther(net: "a", layer: 0).clearance(copper: .plane, nonCopper: .boardEdge), 100_000)
        // keepout fallback: 0.
        XCTAssertEqual(rules.clearanceCopperKeepout(net: "a", keepoutClass: "x").clearance(.plane), 0)
    }

    func testSymmetricCopperClearanceIndexing() {
        let json: [String: Any] = [
            "clearance_copper": [
                "rule1": [
                    "enabled": true, "order": 0, "layer": 10000,
                    "match_1": ["mode": "all", "net": "00000000-0000-0000-0000-000000000000", "net_class": "x", "net_name_regex": ""],
                    "match_2": ["mode": "all", "net": "00000000-0000-0000-0000-000000000000", "net_class": "x", "net_name_regex": ""],
                    "clearances": [
                        ["clearance": 350_000, "types": ["track", "plane"]],
                        ["clearance": 50_000, "types": ["track", "via"]],
                    ],
                ],
            ],
        ]
        let rules = HorizontalBoardRules(rules: json, netDetails: [:])
        let copper = rules.clearanceCopper(net1: "a", net2: "b", layer: 0)
        // Symmetric: (track, plane) == (plane, track).
        XCTAssertEqual(copper.clearance(.track, .plane), 350_000)
        XCTAssertEqual(copper.clearance(.plane, .track), 350_000)
        XCTAssertEqual(copper.clearance(.via, .track), 50_000)
        // Unspecified pair falls back to default.
        XCTAssertEqual(copper.clearance(.pad, .pad), 100_000)
        // netTie maps to track.
        XCTAssertEqual(copper.clearance(.netTie, .plane), 350_000)
    }

    func testCopperOtherOrderedAndTextMapsToOther() {
        let json: [String: Any] = [
            "clearance_copper_other": [
                "rule1": [
                    "enabled": true, "order": 0, "layer": 10000,
                    "match": ["mode": "all", "net": "00000000-0000-0000-0000-000000000000", "net_class": "x", "net_name_regex": ""],
                    "clearances": [
                        ["clearance": 125_000, "types": ["plane", "board_edge"]],
                        ["clearance": 100_000, "types": ["track", "other"]],
                    ],
                ],
            ],
        ]
        let rules = HorizontalBoardRules(rules: json, netDetails: [:])
        let other = rules.clearanceCopperOther(net: "a", layer: 0)
        XCTAssertEqual(other.clearance(copper: .plane, nonCopper: .boardEdge), 125_000)
        // text maps to other for the non-copper argument.
        XCTAssertEqual(other.clearance(copper: .track, nonCopper: .text), 100_000)
    }

    func testPlaneSettingsDefaultsAndSpellings() {
        // Struct default thermal gap is 0.2mm (distinct from the 0.1mm from-JSON default).
        XCTAssertEqual(HorizontalPlaneSettings.default.thermalSettings.thermalGapWidth, 200_000)
        // from-JSON default when a settings object omits the key: 0.1mm.
        let fromEmptyObject = HorizontalThermalSettings(json: [:])
        XCTAssertEqual(fromEmptyObject.thermalGapWidth, 100_000)
        // Swift editor spellings accepted.
        XCTAssertEqual(HorizontalThermalSettings(json: ["connect_style": "none"]).connectStyle, HorizontalThermalSettings.ConnectStyle.none)
        XCTAssertEqual(HorizontalPlaneSettings(json: ["text_style": "clip"]).textStyle, HorizontalPlaneSettings.TextStyle.bbox)
    }

    // MARK: - Per-pad thermal overrides (RuleThermals)

    private static let thermalPackageUUID = "11111111-1111-1111-1111-111111111111"
    private static let thermalPadUUID = "22222222-2222-2222-2222-222222222222"
    private static let thermalOtherUUID = "33333333-3333-3333-3333-333333333333"

    /// A solid-flood plane default, used as the FROM_PLANE / no-match fallback.
    private let planeSolid = HorizontalThermalSettings(
        connectStyle: .solid,
        thermalGapWidth: 200_000,
        thermalSpokeWidth: 200_000,
        nSpokes: 4,
        angle: 0)

    func testThermalsRuleOverridesPlaneDefaultForSpecificPad() {
        let json: [String: Any] = [
            "thermals": [
                "rule1": [
                    "enabled": true, "order": 0, "layer": 10000,
                    "match": ["mode": "all"],
                    "match_component": [
                        "mode": "component",
                        "component": Self.thermalPackageUUID,
                        "part": "00000000-0000-0000-0000-000000000000",
                        "components": [],
                    ],
                    "pad_mode": "pads",
                    "pads": [Self.thermalPadUUID],
                    "connect_style": "thermal",
                    "thermal_gap_width": 300_000,
                    "thermal_spoke_width": 250_000,
                    "n_spokes": 2,
                    "angle": 45,
                ],
            ],
        ]
        let rules = HorizontalBoardRules(rules: json, netDetails: [:])

        // Matching package + pad → the rule's thermal settings override the plane.
        let overridden = rules.thermalSettings(
            net: "some-net", packageID: Self.thermalPackageUUID, padID: Self.thermalPadUUID,
            layer: 0, planeThermal: planeSolid)
        XCTAssertEqual(overridden.connectStyle, .thermal)
        XCTAssertEqual(overridden.thermalGapWidth, 300_000)
        XCTAssertEqual(overridden.thermalSpokeWidth, 250_000)
        XCTAssertEqual(overridden.nSpokes, 2)
        XCTAssertEqual(overridden.angle, 45)

        // A different pad on the same package → plane default (pad not in `pads`).
        let otherPad = rules.thermalSettings(
            net: "some-net", packageID: Self.thermalPackageUUID, padID: Self.thermalOtherUUID,
            layer: 0, planeThermal: planeSolid)
        XCTAssertEqual(otherPad.connectStyle, .solid)
        XCTAssertEqual(otherPad.thermalGapWidth, 200_000)

        // A different package → plane default (component match fails).
        let otherPackage = rules.thermalSettings(
            net: "some-net", packageID: Self.thermalOtherUUID, padID: Self.thermalPadUUID,
            layer: 0, planeThermal: planeSolid)
        XCTAssertEqual(otherPackage.connectStyle, .solid)

        // UUID matching is case-insensitive.
        let upper = rules.thermalSettings(
            net: "some-net", packageID: Self.thermalPackageUUID.uppercased(),
            padID: Self.thermalPadUUID.uppercased(), layer: 0, planeThermal: planeSolid)
        XCTAssertEqual(upper.connectStyle, .thermal)
    }

    func testThermalsRuleHonorsNetAndLayerMatch() {
        let json: [String: Any] = [
            "thermals": [
                "rule1": [
                    "enabled": true, "order": 0, "layer": 0, // top-copper only
                    "match": ["mode": "net", "net": "gnd-net"],
                    "match_component": ["mode": "components", "components": [Self.thermalPackageUUID]],
                    "pad_mode": "all",
                    "connect_style": "thermal",
                    "thermal_gap_width": 400_000,
                ],
            ],
        ]
        let rules = HorizontalBoardRules(rules: json, netDetails: [:])

        func style(net: String, layer: Int) -> HorizontalThermalSettings.ConnectStyle {
            rules.thermalSettings(
                net: net, packageID: Self.thermalPackageUUID, padID: Self.thermalPadUUID,
                layer: layer, planeThermal: planeSolid).connectStyle
        }

        // Right net + right layer (pad_mode all) → override.
        XCTAssertEqual(style(net: "gnd-net", layer: 0), .thermal)
        // Wrong layer → fallback to the plane default.
        XCTAssertEqual(style(net: "gnd-net", layer: 5), .solid)
        // Wrong net → fallback.
        XCTAssertEqual(style(net: "vcc-net", layer: 0), .solid)
    }

    func testThermalsRuleFromPlaneFallsBackToPlaneSettings() {
        let json: [String: Any] = [
            "thermals": [
                "rule1": [
                    "enabled": true, "order": 0, "layer": 10000,
                    "match": ["mode": "all"],
                    "match_component": ["mode": "component", "component": Self.thermalPackageUUID],
                    "pad_mode": "all",
                    "connect_style": "from_plane",
                ],
            ],
        ]
        let rules = HorizontalBoardRules(rules: json, netDetails: [:])

        // The rule matches but is FROM_PLANE, so the plane's own settings win.
        let planeThermal = HorizontalThermalSettings(
            connectStyle: .thermal, thermalGapWidth: 150_000,
            thermalSpokeWidth: 220_000, nSpokes: 3, angle: 0)
        let resolved = rules.thermalSettings(
            net: "some-net", packageID: Self.thermalPackageUUID, padID: Self.thermalPadUUID,
            layer: 0, planeThermal: planeThermal)
        XCTAssertEqual(resolved.connectStyle, .thermal)
        XCTAssertEqual(resolved.thermalGapWidth, 150_000)
        XCTAssertEqual(resolved.nSpokes, 3)
    }

    func testDisabledThermalsRuleIsIgnored() {
        let json: [String: Any] = [
            "thermals": [
                "rule1": [
                    "enabled": false, "order": 0, "layer": 10000,
                    "match": ["mode": "all"],
                    "match_component": ["mode": "component", "component": Self.thermalPackageUUID],
                    "pad_mode": "all",
                    "connect_style": "thermal",
                ],
            ],
        ]
        let rules = HorizontalBoardRules(rules: json, netDetails: [:])
        let resolved = rules.thermalSettings(
            net: "some-net", packageID: Self.thermalPackageUUID, padID: Self.thermalPadUUID,
            layer: 0, planeThermal: planeSolid)
        XCTAssertEqual(resolved.connectStyle, .solid)
    }
}
