import XCTest
@testable import HorizontalNative

/// Guards the byte-faithful on-disk round-trip for via and board-hole
/// parameter edits (the sidebar padstack/parameter inspector). Horizon
/// serializes a via as `{ junction, padstack, parameter_set, from_rules,
/// source, definition, net_set, locked }` (board/via.cpp Via::serialize) and a
/// board hole as `{ placement, padstack, parameter_set, net }`
/// (board/board_hole.cpp) — geometry lives in parameter_set for both, so the
/// applicator must write parameters there and never invent direct keys.
final class HorizontalViaParameterPersistenceTests: XCTestCase {

    private func via(
        size: Double = 500_000,
        holeSize: Double? = 250_000,
        padstackID: String? = nil,
        definitionID: String? = nil,
        fromRules: Bool = false,
        parameterSet: [String: Double] = [:]
    ) -> HorizontalMarker {
        HorizontalMarker(
            id: "via-1",
            position: HorizontalPoint(x: 0, y: 0),
            size: size,
            holeSize: holeSize,
            layer: nil,
            connectedLayers: [],
            netID: nil,
            padstackID: padstackID,
            definitionID: definitionID,
            fromRules: fromRules,
            parameterSet: parameterSet
        )
    }

    // MARK: - Via parameter set

    func testViaEntryWritesFullParameterSetWithModelGeometryAuthoritative() {
        let existing: JSONDictionary = [
            "padstack": "pad-uuid",
            "parameter_set": [
                "via_diameter": 400_000,
                "hole_diameter": 200_000,
                "solder_mask_expansion": 50_000,
            ] as JSONDictionary,
        ]
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(size: 600_000, holeSize: 300_000, parameterSet: [
                "via_diameter": 600_000,
                "hole_diameter": 300_000,
                "solder_mask_expansion": 75_000,
            ]),
            existing: existing
        )
        let parameters = entry["parameter_set"] as? JSONDictionary
        XCTAssertEqual(parameters?["via_diameter"] as? Int, 600_000)
        XCTAssertEqual(parameters?["hole_diameter"] as? Int, 300_000)
        XCTAssertEqual(parameters?["solder_mask_expansion"] as? Int, 75_000)
    }

    func testUnknownNumericParametersRoundTripThroughTheModel() {
        // The parse lifts every numeric entry into the model's parameterSet, so
        // an unknown-but-numeric parameter survives by riding the model — not
        // by the applicator merging the old entry back in.
        let existing: JSONDictionary = [
            "parameter_set": ["future_parameter": 12_345] as JSONDictionary
        ]
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(parameterSet: ["future_parameter": 12_345]),
            existing: existing
        )
        let parameters = entry["parameter_set"] as? JSONDictionary
        XCTAssertEqual(parameters?["future_parameter"] as? Int, 12_345)
        XCTAssertEqual(parameters?["via_diameter"] as? Int, 500_000)
        XCTAssertEqual(parameters?["hole_diameter"] as? Int, 250_000)
    }

    func testRemovedParameterIsDeletedFromDisk() {
        // The inspector's (X) removes the key from the model's parameterSet;
        // the entry must not resurrect it from the existing JSON.
        let existing: JSONDictionary = [
            "parameter_set": [
                "via_diameter": 500_000,
                "hole_diameter": 250_000,
                "solder_mask_expansion": 75_000,
            ] as JSONDictionary
        ]
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(parameterSet: ["via_diameter": 500_000, "hole_diameter": 250_000]),
            existing: existing
        )
        let parameters = entry["parameter_set"] as? JSONDictionary
        XCTAssertNil(parameters?["solder_mask_expansion"], "a removed parameter must stay removed on save")
        XCTAssertEqual(parameters?["via_diameter"] as? Int, 500_000)
    }

    func testNonNumericForeignParameterEntriesSurviveVerbatim() {
        // Horizon parameters are int64, so a non-numeric value is foreign data
        // the model can't carry — the entry keeps it untouched.
        let existing: JSONDictionary = [
            "parameter_set": ["future_flag": "experimental"] as JSONDictionary
        ]
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(via(), existing: existing)
        let parameters = entry["parameter_set"] as? JSONDictionary
        XCTAssertEqual(parameters?["future_flag"] as? String, "experimental")
    }

    // MARK: - Padstack reference

    func testViaEntryKeepsPadstackCasingWhenUnchanged() {
        let existing: JSONDictionary = ["padstack": "ABCD-EF"]
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(padstackID: "abcd-ef"),
            existing: existing
        )
        XCTAssertEqual(entry["padstack"] as? String, "ABCD-EF")
    }

    func testViaEntryRewritesPadstackWhenChanged() {
        let existing: JSONDictionary = ["padstack": "old-uuid"]
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(padstackID: "new-uuid"),
            existing: existing
        )
        XCTAssertEqual(entry["padstack"] as? String, "new-uuid")
    }

    // MARK: - from_rules / source / definition

    func testAbsentFromRulesStaysAbsentWhenModelMatchesTheDefault() {
        // Horizon treats a missing from_rules as true; an untouched rules via
        // must not grow the key on an unrelated save.
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(via(fromRules: true), existing: [:])
        XCTAssertNil(entry["from_rules"])
        XCTAssertNil(entry["source"])
    }

    func testAbsentFromRulesIsMaterializedWhenTheViaGoesLocal() {
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(via(fromRules: false), existing: [:])
        XCTAssertEqual(entry["from_rules"] as? Bool, false)
    }

    func testPresentFromRulesFollowsTheModel() {
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(fromRules: false),
            existing: ["from_rules": true]
        )
        XCTAssertEqual(entry["from_rules"] as? Bool, false)
    }

    func testSourceIsKeptInSyncWhenTheFileSpeaksIt() {
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(fromRules: false),
            existing: ["source": "rules", "from_rules": true]
        )
        XCTAssertEqual(entry["source"] as? String, "local")
        XCTAssertEqual(entry["from_rules"] as? Bool, false)
    }

    func testChoosingADefinitionWritesDefinitionAndSource() {
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(definitionID: "def-uuid"),
            existing: [:]
        )
        XCTAssertEqual(entry["definition"] as? String, "def-uuid")
        XCTAssertEqual(entry["source"] as? String, "definition")
    }

    func testClearingADefinitionRemovesTheKey() {
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(
            via(definitionID: nil),
            existing: ["definition": "def-uuid", "source": "definition"]
        )
        XCTAssertNil(entry["definition"])
        XCTAssertEqual(entry["source"] as? String, "local")
    }

    // MARK: - Board holes

    private func hole(
        diameter: Double = 1_000_000,
        shape: HorizontalHoleShape = .round,
        padstackID: String? = nil,
        parameterSet: [String: Double] = [:]
    ) -> HorizontalHole {
        HorizontalHole(
            id: "hole-1",
            position: HorizontalPoint(x: 1_000, y: 2_000),
            diameter: diameter,
            length: diameter,
            shape: shape,
            angle: 0,
            plated: false,
            padstackID: padstackID,
            parameterSet: parameterSet
        )
    }

    func testPadstackHoleWritesParametersNotDirectKeys() {
        let existing: JSONDictionary = [
            "padstack": "hole-padstack",
            "parameter_set": ["hole_diameter": 900_000] as JSONDictionary,
        ]
        let entry = HorizontalProjectJSONApplicator.holeJSONEntry(
            hole(diameter: 1_100_000, padstackID: "hole-padstack", parameterSet: ["hole_diameter": 1_100_000]),
            existing: existing
        )
        let parameters = entry["parameter_set"] as? JSONDictionary
        XCTAssertEqual(parameters?["hole_diameter"] as? Int, 1_100_000)
        XCTAssertNil(parameters?["hole_length"], "a round hole must not grow hole_length")
        XCTAssertNil(entry["diameter"], "BoardHole entries carry no direct geometry keys")
        XCTAssertNil(entry["shape"])
        XCTAssertNil(entry["plated"])
    }

    func testSlotPadstackHoleWritesHoleLength() {
        var slot = hole(diameter: 500_000, shape: .slot, padstackID: "hole-padstack")
        slot.length = 900_000
        let entry = HorizontalProjectJSONApplicator.holeJSONEntry(slot, existing: ["padstack": "hole-padstack"])
        let parameters = entry["parameter_set"] as? JSONDictionary
        XCTAssertEqual(parameters?["hole_length"] as? Int, 900_000)
    }

    func testPlainHoleKeepsDirectGeometryKeys() {
        let entry = HorizontalProjectJSONApplicator.holeJSONEntry(hole(), existing: [:])
        XCTAssertEqual(entry["diameter"] as? Int, 1_000_000)
        XCTAssertEqual(entry["shape"] as? String, "round")
        XCTAssertEqual(entry["plated"] as? Bool, false)
        XCTAssertNil(entry["parameter_set"])
    }
}
