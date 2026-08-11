import XCTest
@testable import HorizontalNative

/// Guards the byte-faithful on-disk round-trip for board planes (Phase 6 plane
/// editor). Horizon serializes a plane as `{ net, polygon, priority, from_rules,
/// settings{...} }` (board/plane.cpp `Plane::serialize` + `PlaneSettings::serialize`
/// + `ThermalSettings::serialize` inlined). These tests pin the exact key set,
/// value types, enum spellings, and that the applicator's output parses back into
/// an identical `HorizontalPlaneSettings` (loader↔applicator parity).
final class HorizontalPlanePersistenceTests: XCTestCase {

    private func settings(from json: JSONDictionary) -> HorizontalPlaneSettings {
        HorizontalPlaneSettings(json: json)
    }

    // MARK: - PlaneSettings schema

    func testPlaneSettingsJSONEmitsExactHorizonSchema() {
        let json = HorizontalProjectJSONApplicator.planeSettingsJSON(.default, existing: nil)
        // Every key Horizon's PlaneSettings::serialize + ThermalSettings::serialize writes.
        let requiredKeys: Set<String> = [
            "min_width", "keep_orphans", "style",
            "connect_style", "thermal_gap_width", "thermal_spoke_width", "n_spokes", "angle",
            "text_style", "fill_style",
            "hatch_border_width", "hatch_line_spacing", "hatch_line_width",
        ]
        XCTAssertEqual(Set(json.keys), requiredKeys, "settings keys must match Horizon exactly")

        // Spot-check value types/spellings against the C++ struct defaults.
        XCTAssertEqual(json["min_width"] as? Int, 200_000)
        XCTAssertEqual(json["keep_orphans"] as? Bool, false)
        XCTAssertEqual(json["style"] as? String, "round")
        XCTAssertEqual(json["connect_style"] as? String, "solid")
        XCTAssertEqual(json["thermal_gap_width"] as? Int, 200_000) // struct default (0.2mm)
        XCTAssertEqual(json["thermal_spoke_width"] as? Int, 200_000)
        XCTAssertEqual(json["n_spokes"] as? Int, 4)
        XCTAssertEqual(json["angle"] as? Int, 0)
        XCTAssertEqual(json["text_style"] as? String, "expand")
        XCTAssertEqual(json["fill_style"] as? String, "solid")
    }

    func testPlaneSettingsEnumSpellingsRoundTrip() {
        // Build settings with every non-default enum, serialize, and confirm the
        // exact Horizon strings, then parse back to the same enum values.
        let source: JSONDictionary = [
            "min_width": 150_000,
            "keep_orphans": true,
            "style": "miter",
            "connect_style": "from_plane",
            "thermal_gap_width": 120_000,
            "thermal_spoke_width": 250_000,
            "n_spokes": 8,
            "angle": 45,
            "text_style": "bbox",
            "fill_style": "hatch",
            "hatch_border_width": 600_000,
            "hatch_line_spacing": 700_000,
            "hatch_line_width": 300_000,
        ]
        let parsed = settings(from: source)
        let json = HorizontalProjectJSONApplicator.planeSettingsJSON(parsed, existing: nil)

        XCTAssertEqual(json["style"] as? String, "miter")
        XCTAssertEqual(json["connect_style"] as? String, "from_plane")
        XCTAssertEqual(json["text_style"] as? String, "bbox")
        XCTAssertEqual(json["fill_style"] as? String, "hatch")
        XCTAssertEqual(json["n_spokes"] as? Int, 8)
        XCTAssertEqual(json["angle"] as? Int, 45)
        XCTAssertEqual(json["keep_orphans"] as? Bool, true)

        // Loader↔applicator parity: re-parsing the emitted JSON yields the same struct.
        XCTAssertEqual(settings(from: json), parsed)
    }

    func testPlaneSettingsJSONPreservesUnknownKeys() {
        let existing: JSONDictionary = ["future_horizon_key": 7, "style": "square"]
        let json = HorizontalProjectJSONApplicator.planeSettingsJSON(.default, existing: existing)
        XCTAssertEqual(json["future_horizon_key"] as? Int, 7, "unknown keys must survive a save")
        XCTAssertEqual(json["style"] as? String, "round", "modeled keys are overwritten from the struct")
    }

    // MARK: - Plane entry schema

    private func plane(net: String?, polygon: String, priority: Int = 0, fromRules: Bool = true) -> HorizontalPlane {
        HorizontalPlane(
            id: "plane-1",
            netID: net,
            polygonID: polygon,
            layer: 0,
            priority: priority,
            fillStyle: "solid",
            minWidth: 0,
            keepOrphans: false,
            fragments: [],
            fallbackPolygon: nil,
            fromRules: fromRules
        )
    }

    func testNewPlaneEntryHasFullHorizonSchema() {
        let entry = HorizontalProjectJSONApplicator.planeJSONEntry(
            plane(net: "gnd-uuid", polygon: "poly-uuid", priority: 3, fromRules: false),
            existing: nil
        )
        XCTAssertEqual(entry["net"] as? String, "gnd-uuid")
        XCTAssertEqual(entry["polygon"] as? String, "poly-uuid")
        XCTAssertEqual(entry["priority"] as? Int, 3)
        XCTAssertEqual(entry["from_rules"] as? Bool, false)
        XCTAssertNotNil(entry["settings"] as? JSONDictionary)
        XCTAssertNil(entry["fragments"], "fragments belong in the plane cache, never board.json")
    }

    func testExistingPlaneEntryKeepsNetCasingWhenUnchanged() {
        // netID is normalized (lowercased) at load; an unchanged net must keep its
        // original on-disk casing rather than being rewritten lowercase.
        let existing: JSONDictionary = ["net": "ABCD-EF", "polygon": "poly", "extra": true]
        let entry = HorizontalProjectJSONApplicator.planeJSONEntry(
            plane(net: "abcd-ef", polygon: "poly"),
            existing: existing
        )
        XCTAssertEqual(entry["net"] as? String, "ABCD-EF", "unchanged net preserves original casing")
        XCTAssertEqual(entry["extra"] as? Bool, true, "unknown top-level keys survive")
    }

    func testChangedNetIsRewritten() {
        let existing: JSONDictionary = ["net": "old-net", "polygon": "poly"]
        let entry = HorizontalProjectJSONApplicator.planeJSONEntry(
            plane(net: "new-net", polygon: "poly"),
            existing: existing
        )
        XCTAssertEqual(entry["net"] as? String, "new-net")
    }
}
