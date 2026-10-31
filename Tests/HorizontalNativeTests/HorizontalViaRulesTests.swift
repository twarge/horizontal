import XCTest
@testable import HorizontalNative

/// Horizon's Apply for the via rules (`HorizontalViaRules`), which the rules
/// window's Apply and MCP's re-derivation after a rule change share: a via
/// that takes its shape from the rules gets its rule's padstack and
/// parameters; one with a shape of its own, or on no net, keeps what it has.
final class HorizontalViaRulesTests: XCTestCase {
    private let padstack = "8b6dee4b-af88-4c0f-b38b-c5364649e65e"
    private let narrowPadstack = "3c4a52fe-3ae0-4c3e-a108-824b53d6d6da"
    private let signalClass = "87ff40af-f2b2-4ae2-81e9-6242c7736b17"

    /// A rule for every net, then a narrower one for the SIG class first.
    private var rules: JSONDictionary {
        ["via": [
            "every": ["enabled": true, "order": 1, "padstack": padstack,
                      "match": ["mode": "all"], "parameter_set": ["via_diameter": 450_000, "hole_diameter": 200_000]],
            "narrow": ["enabled": true, "order": 0, "padstack": narrowPadstack,
                       "match": ["mode": "net_class", "net_class": signalClass],
                       "parameter_set": ["via_diameter": 300_000, "hole_diameter": 150_000]],
        ] as JSONDictionary]
    }

    private let netDetails: [String: HorizontalNetDetails] = [
        "gnd": HorizontalNetDetails(id: "gnd", name: "GND", netClassID: nil, netClassName: nil),
        "sig": HorizontalNetDetails(id: "sig", name: "SIG", netClassID: "87ff40af-f2b2-4ae2-81e9-6242c7736b17", netClassName: "SIG"),
    ]

    private func via(_ source: String?, padstack: String, parameters: JSONDictionary) -> JSONDictionary {
        var via: JSONDictionary = ["junction": "j", "padstack": padstack, "parameter_set": parameters]
        if let source { via["source"] = source } else { via["from_rules"] = true }
        return via
    }

    func testARuleShapedViaTakesItsRulesShape() throws {
        let vias: [String: JSONDictionary] = [
            // As Weevling's were: from the rules, with only a diameter.
            "stale": via(nil, padstack: padstack, parameters: ["via_diameter": 450_000]),
            "signal": via("rules", padstack: padstack, parameters: ["via_diameter": 450_000, "hole_diameter": 200_000]),
            "current": via("rules", padstack: padstack, parameters: ["via_diameter": 450_000, "hole_diameter": 200_000]),
            "local": via("local", padstack: padstack, parameters: ["via_diameter": 900_000, "hole_diameter": 500_000]),
            "netless": via("rules", padstack: padstack, parameters: ["via_diameter": 450_000]),
        ]
        let nets = ["stale": "gnd", "signal": "sig", "current": "gnd", "local": "gnd"]
        let applied = HorizontalViaRules.applied(to: vias, rules: rules, netDetails: netDetails) { id, _ in nets[id] }

        XCTAssertEqual(applied.changed.sorted(), ["signal", "stale"], "the ones already as their rule gives are left")
        let stale = try XCTUnwrap(applied.vias["stale"])
        XCTAssertEqual(stale.dictionary("parameter_set")?.int("hole_diameter"), 200_000)
        XCTAssertEqual(stale.string("padstack"), padstack)
        XCTAssertEqual(stale.bool("from_rules"), true, "it goes on taking its shape from the rules")
        let signal = try XCTUnwrap(applied.vias["signal"])
        XCTAssertEqual(signal.string("padstack"), narrowPadstack, "the first rule by order that takes its net")
        XCTAssertEqual(signal.dictionary("parameter_set")?.int("via_diameter"), 300_000)
        XCTAssertEqual(applied.vias["local"]?.dictionary("parameter_set")?.int("via_diameter"), 900_000)
        XCTAssertNil(applied.vias["netless"]?.dictionary("parameter_set")?.int("hole_diameter"), "Horizon leaves a via on no net")
    }

    /// A disabled rule, or one that names no padstack, shapes nothing.
    func testADisabledOrPadstacklessRuleShapesNothing() {
        var rules = self.rules
        var family = rules.dictionaryMap("via")
        family["narrow"]?["enabled"] = false
        family["every"]?["padstack"] = "00000000-0000-0000-0000-000000000000"
        rules["via"] = family
        let applied = HorizontalViaRules.applied(
            to: ["v": via("rules", padstack: padstack, parameters: ["via_diameter": 1])],
            rules: rules, netDetails: netDetails) { _, _ in "sig" }
        XCTAssertTrue(applied.changed.isEmpty)
    }
}
