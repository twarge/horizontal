import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The pool item models: parse → `json()` reproduces the source, unknown keys
/// survive, and the conditional keys follow Horizon's own serializers.
final class HorizontalPoolModelTests: XCTestCase {
    // MARK: - Unit

    func testUnitRoundTripsModernAlternateNamesAndUnknownKeys() throws {
        let json: JSONDictionary = [
            "type": "unit", "uuid": "u1", "name": "MCU", "manufacturer": "Acme", "version": 1,
            "custom_note": "kept",
            "pins": [
                "p1": [
                    "primary_name": "PA0", "direction": "bidirectional", "swap_group": 0, "names": [],
                    "alt_names": ["a1": ["name": "UART_TX", "direction": "output"]],
                    "extra": true,
                ],
            ],
        ]
        let unit = try HorizontalPoolUnit(json: json)
        XCTAssertEqual(unit.pins["p1"]?.alternateNames, [
            HorizontalUnitPinAlternateName(id: "a1", name: "UART_TX", direction: .output),
        ])
        XCTAssertEqual(unit.requiredVersion, 1)
        XCTAssertTrue(NSDictionary(dictionary: unit.json()).isEqual(to: json))
    }

    func testUnitDerivesLegacyNameIDsAndKeepsTheLegacyEncodingUntilEdited() throws {
        let json: JSONDictionary = [
            "type": "unit", "uuid": "u1", "name": "R",
            "pins": ["p1": ["primary_name": "A", "direction": "passive", "names": ["X", "Y"]]],
        ]
        var unit = try HorizontalPoolUnit(json: json)
        let alternates = try XCTUnwrap(unit.pins["p1"]?.alternateNames)
        XCTAssertEqual(Set(alternates.map(\.id)), [
            "9251d5a5-6c95-552f-b241-a22c61860edf",
            "bb4bb488-8cd0-5079-9672-764ea34a5f1a",
        ])
        XCTAssertEqual(alternates.map(\.direction), [.passive, .passive])
        XCTAssertEqual(unit.requiredVersion, 0)
        XCTAssertTrue(NSDictionary(dictionary: unit.json()).isEqual(to: json), "untouched legacy names stay legacy")

        unit.pins["p1"]?.alternateNames.append(HorizontalUnitPinAlternateName(id: "n3", name: "Z", direction: .input))
        let written = unit.json()
        XCTAssertEqual(written["version"] as? Int, 1)
        let pin = try XCTUnwrap(written.dictionaryMap("pins")["p1"])
        XCTAssertEqual(pin["names"] as? [String], [])
        XCTAssertEqual(pin.dictionaryMap("alt_names").count, 3)
        XCTAssertEqual(pin.dictionaryMap("alt_names")["n3"]?["direction"] as? String, "input")
    }

    func testUUID5MatchesHorizonGoldens() {
        XCTAssertEqual(UUID.horizonAlternatePinNameID(index: 0), "9251d5a5-6c95-552f-b241-a22c61860edf")
        XCTAssertEqual(UUID.horizonAlternatePinNameID(index: 1), "bb4bb488-8cd0-5079-9672-764ea34a5f1a")
        XCTAssertEqual(UUID.horizonAlternatePinNameID(index: 2), "49ffcb91-4c83-5896-aecd-31f34e7118d6")
    }

    func testNewUnitPinWritesTheFullUpstreamSet() throws {
        var unit = HorizontalPoolUnit(uuid: "u1", name: "New")
        unit.pins["p1"] = HorizontalUnitPin(id: "p1", primaryName: "1", direction: .passive)
        let pin = try XCTUnwrap(unit.json().dictionaryMap("pins")["p1"])
        XCTAssertEqual(pin["swap_group"] as? Int, 0)
        XCTAssertEqual(pin["names"] as? [String], [])
        XCTAssertNil(pin["alt_names"])
        XCTAssertEqual(unit.json()["manufacturer"] as? String, "")
    }

    func testUnitChecksMirrorUpstream() throws {
        var unit = HorizontalPoolUnit(uuid: "u1", name: " R ")
        unit.pins["a"] = HorizontalUnitPin(id: "a", primaryName: "A")
        unit.pins["b"] = HorizontalUnitPin(id: "b", primaryName: "A", alternateNames: [
            HorizontalUnitPinAlternateName(id: "x", name: "A", direction: .input),
            HorizontalUnitPinAlternateName(id: "y", name: "B,C", direction: .input),
        ])
        let messages = unit.validationIssues().map(\.message)
        XCTAssertTrue(messages.contains("Name has trailing/leading whitespace"))
        XCTAssertTrue(messages.contains("Pin \"A\" not unique"))
        XCTAssertTrue(messages.contains("Alt. name of pin \"A\" must not repeat primary name"))
        XCTAssertTrue(messages.contains("Alt. name \"B,C\" of pin \"A\" contains comma or semicolon"))
    }

    // MARK: - Entity

    func testEntityRoundTripAndChecks() throws {
        let json: JSONDictionary = [
            "type": "entity", "uuid": "e1", "name": "Dual op-amp", "manufacturer": "", "prefix": "U",
            "tags": ["opamp"],
            "gates": [
                "g1": ["name": "A", "suffix": "A", "swap_group": 1, "unit": "u1"],
                "g2": ["name": "B", "suffix": "B", "swap_group": 1, "unit": "u1"],
            ],
        ]
        let entity = try HorizontalPoolEntity(json: json)
        XCTAssertTrue(NSDictionary(dictionary: entity.json()).isEqual(to: json))
        XCTAssertEqual(entity.validationIssues(), [])

        var broken = entity
        broken.gates["g2"]?.suffix = "a"
        broken.tags = ["Bad Tag"]
        let messages = broken.validationIssues().map(\.message)
        XCTAssertTrue(messages.contains("Gate suffix \"a\" must be one or more capital letters"))
        XCTAssertTrue(messages.contains("Tag \"Bad Tag\" must only contain lowercase letters, digits, dots or dashes"))
    }

    // MARK: - Part

    func testPartWritesBaseOrEntityExclusively() throws {
        let full: JSONDictionary = [
            "type": "part", "uuid": "p1",
            "MPN": [false, "ABC"], "value": [false, ""], "manufacturer": [false, "Acme"],
            "datasheet": [false, "https://example.com/x.pdf"], "description": [false, "Thing"],
            "tags": ["x"], "inherit_tags": false, "parametric": [:], "model": "00000000-0000-0000-0000-000000000000",
            "inherit_model": true, "entity": "e1", "package": "k1",
            "pad_map": ["pad1": ["gate": "g1", "pin": "n1"]],
        ]
        var part = try HorizontalPoolPartItem(json: full)
        XCTAssertTrue(NSDictionary(dictionary: part.json()).isEqual(to: full))
        XCTAssertEqual(part.name, "ABC")

        part.baseID = "base"
        part.attributes[.mpn] = HorizontalPartAttribute(inherited: true, value: "ABC")
        let written = part.json()
        XCTAssertEqual(written["base"] as? String, "base")
        XCTAssertNil(written["entity"])
        XCTAssertNil(written["package"])
        XCTAssertNil(written["pad_map"])
        XCTAssertEqual((written["MPN"] as? [Any])?.first as? Bool, true)
    }

    func testPartVersionFollowsFlagsAndPrefixOverride() throws {
        var part = HorizontalPoolPartItem(uuid: "p1", entityID: "e1", packageID: "k1", mpn: "X")
        XCTAssertEqual(part.requiredVersion, 0)
        XCTAssertNil(part.json()["flags"])
        XCTAssertNil(part.json()["version"])

        part.flags[.excludeBOM] = .set
        XCTAssertEqual(part.requiredVersion, 1)
        XCTAssertEqual((part.json()["flags"] as? JSONDictionary)?.count, 3)
        XCTAssertEqual(part.json()["version"] as? Int, 1)

        part.overridePrefix = .yes
        part.prefix = "R"
        XCTAssertEqual(part.requiredVersion, 2)
        XCTAssertEqual(part.json()["override_prefix"] as? String, "yes")
        XCTAssertEqual(part.json()["prefix"] as? String, "R")

        part.overridePrefix = .no
        XCTAssertNil(part.json()["override_prefix"])
        XCTAssertNil(part.json()["prefix"])
    }

    func testPartOptionalAttributesStayAbsentWhenDefault() throws {
        let json: JSONDictionary = [
            "type": "part", "uuid": "p1", "MPN": [false, "X"], "value": [false, ""],
            "manufacturer": [false, ""], "entity": "e1", "package": "k1", "pad_map": [:],
        ]
        let part = try HorizontalPoolPartItem(json: json)
        XCTAssertTrue(NSDictionary(dictionary: part.json()).isEqual(to: json))
    }

    // MARK: - Symbol

    func testSymbolRoundTripsPinsTextsAndLegacyPlacements() throws {
        let json: JSONDictionary = [
            "type": "symbol", "uuid": "s1", "name": "R", "unit": "u1",
            "junctions": ["j1": ["position": [0, 0]], "j2": ["position": [1_250_000, 0]]],
            "lines": ["l1": ["from": "j1", "to": "j2", "width": 0, "layer": 0]],
            "arcs": ["a1": ["from": "j1", "to": "j2", "center": "j1", "width": 0, "layer": 0]],
            "polygons": ["q1": ["layer": 0, "parameter_class": "", "vertices": [
                ["type": "line", "position": [0, 0], "arc_center": [0, 0], "arc_reverse": false],
                ["type": "arc", "position": [1, 0], "arc_center": [0, 0], "arc_reverse": true],
                ["type": "line", "position": [0, 1], "arc_center": [0, 0], "arc_reverse": false],
            ]]],
            "texts": [
                "t1": ["origin": "center", "text": "$REFDES", "size": 1_500_000, "width": 0, "layer": 0,
                       "placement": ["shift": [0, 2_500_000], "angle": 0, "mirror": false]],
                "t2": ["origin": "baseline", "font": "complex", "text": "", "size": 1_500_000, "width": 0,
                       "layer": 0, "from_smash": false, "allow_upside_down": true,
                       "placement": ["shift": [0, -2_500_000], "angle": 16_384, "mirror": true]],
            ],
            "pins": [
                "p1": ["position": [-2_500_000, 0], "length": 2_500_000, "orientation": "right",
                       "name_visible": false, "pad_visible": true, "keep_horizontal": true,
                       "decoration": ["dot": true, "clock": false, "schmitt": true, "driver": "tristate"]],
                "p2": ["position": [2_500_000, 0], "length": 2_500_000, "orientation": "left"],
            ],
            "text_placements": ["90m": ["t1": ["shift": [1, 2], "angle": 16_384, "mirror": true]]],
        ]
        var symbol = try HorizontalPoolSymbol(json: json)
        XCTAssertEqual(symbol.pins["p1"]?.nameOrientation, .horizontal)
        XCTAssertEqual(symbol.pins["p1"]?.decoration.driver, .tristate)
        XCTAssertEqual(symbol.pins["p2"]?.decoration, HorizontalSymbolPinDecoration())
        XCTAssertEqual(symbol.drawing.texts["t2"]?.font, .complex)
        XCTAssertEqual(symbol.drawing.polygons["q1"]?.vertices.count, 3)
        XCTAssertTrue(symbol.textPlacementsAreLegacy)
        XCTAssertEqual(symbol.correctedTextPlacements["90m"]?["t1"]?.angle, HorizontalPlacementTransform(shift: .zero, angle: -16_384, mirrored: true).angle)
        XCTAssertEqual(symbol.requiredVersion, 0)
        XCTAssertTrue(NSDictionary(dictionary: symbol.json()).isEqual(to: json))

        // Editing the placements makes the file a version-1 file.
        symbol.textPlacements = symbol.correctedTextPlacements
        symbol.textPlacementsAreLegacy = false
        XCTAssertEqual(symbol.json()["version"] as? Int, 1)

        // A pin that changes its name orientation drops the legacy flag.
        symbol.pins["p1"]?.nameOrientation = .inLine
        let pin = try XCTUnwrap(symbol.json().dictionaryMap("pins")["p1"])
        XCTAssertNil(pin["keep_horizontal"])
        XCTAssertEqual(pin["name_orientation"] as? String, "in_line")
    }

    func testNewSymbolPinAndTextWriteTheFullUpstreamSet() throws {
        var symbol = HorizontalPoolSymbol(uuid: "s1", name: "N", unitID: "u1")
        symbol.pins["p1"] = HorizontalSymbolPin(id: "p1", position: .zero)
        symbol.drawing.texts["t1"] = HorizontalPoolText(id: "t1", text: "$VALUE", placement: .identity)
        let json = symbol.json()
        let pin = try XCTUnwrap(json.dictionaryMap("pins")["p1"])
        XCTAssertEqual(Set(pin.keys), ["position", "length", "orientation", "name_visible", "pad_visible", "name_orientation", "decoration"])
        let text = try XCTUnwrap(json.dictionaryMap("texts")["t1"])
        XCTAssertEqual(Set(text.keys), ["origin", "font", "text", "size", "width", "layer", "from_smash", "placement"])
        XCTAssertEqual(json["can_expand"] as? Bool, false)
        XCTAssertEqual((json["text_placements"] as? JSONDictionary)?.isEmpty, true)
    }

    // MARK: - Package / padstack / frame / decal

    func testPackageVersionAndConditionalKeys() throws {
        var package = HorizontalPoolPackage(uuid: "k1", name: "R0603")
        XCTAssertNil(package.json()["version"])
        XCTAssertNil(package.json()["parameters_fixed"])
        XCTAssertNil(package.json()["alternate_for"])
        XCTAssertEqual(package.nextPadName(), "1")

        package.pads["pad1"] = HorizontalPad(id: "pad1", name: "1", padstackID: "ps1", parametersFixed: ["pad_width"])
        XCTAssertEqual(package.requiredVersion, 1)
        XCTAssertEqual(package.nextPadName(), "2")
        var model = HorizontalPackageModel3D(id: "m1", filename: "3d_models/r.step")
        model.heightTop = 500_000
        package.models["m1"] = model
        package.defaultModelID = "m1"
        XCTAssertEqual(package.requiredVersion, 2)
        package.alternateForID = "k1"
        XCTAssertNil(package.json()["alternate_for"], "a package is never an alternate for itself")
        package.alternateForID = "k2"
        XCTAssertEqual(package.json()["alternate_for"] as? String, "k2")
        let modelJSON = try XCTUnwrap(package.json().dictionaryMap("models")["m1"])
        XCTAssertEqual(modelJSON["height_top"] as? Int, 500_000)
        XCTAssertEqual(modelJSON["height_bot"] as? Int, 0)
    }

    func testPadstackRoundTripAndHoleSpan() throws {
        let json: JSONDictionary = [
            "type": "padstack", "uuid": "ps1", "name": "Via", "well_known_name": "", "padstack_type": "via",
            "parameter_program": "get-parameter [ via_diameter ]\nset-shape [ via circle ]\n",
            "parameter_set": ["via_diameter": 700_000], "parameters_required": ["via_diameter"],
            "polygons": [:],
            "holes": ["h1": ["placement": ["shift": [0, 0], "angle": 0, "mirror": false], "diameter": 400_000,
                             "length": 400_000, "shape": "round", "plated": true, "parameter_class": "hole",
                             "span": ["start": 0, "end": -100]]],
            "shapes": ["s1": ["placement": ["shift": [0, 0], "angle": 0, "mirror": false], "layer": 0,
                              "form": "circle", "params": [700_000], "parameter_class": "via"]],
        ]
        let padstack = try HorizontalPoolPadstack(json: json)
        XCTAssertEqual(padstack.type, .via)
        XCTAssertEqual(padstack.shapes["s1"]?.form, .circle)
        XCTAssertNotNil(padstack.holes["h1"]?.span)
        XCTAssertTrue(NSDictionary(dictionary: padstack.json()).isEqual(to: json))
    }

    func testFrameAndDecalRoundTrip() throws {
        let frameJSON: JSONDictionary = [
            "type": "frame", "uuid": "f1", "name": "A4", "width": 297_000_000, "height": 210_000_000,
            "junctions": [:], "lines": [:], "arcs": [:], "polygons": [:], "texts": [:],
        ]
        let frame = try HorizontalPoolFrame(json: frameJSON)
        XCTAssertTrue(NSDictionary(dictionary: frame.json()).isEqual(to: frameJSON))

        let decalJSON: JSONDictionary = [
            "type": "decal", "uuid": "d1", "name": "Logo",
            "junctions": ["j1": ["position": [0, 0]], "j2": ["position": [10, 0]]],
            "lines": ["l1": ["from": "j1", "to": "j2", "width": 100_000, "layer": 20]],
        ]
        let decal = try HorizontalPoolDecal(json: decalJSON)
        XCTAssertTrue(NSDictionary(dictionary: decal.json()).isEqual(to: decalJSON))
        XCTAssertNil(decal.json()["arcs"], "empty maps the source lacked stay absent")
    }

    func testModelEnumDispatchesOnType() throws {
        let model = try HorizontalPoolItemModel.load(json: ["type": "decal", "uuid": "d1", "name": "X"])
        XCTAssertEqual(model.category, .decal)
        XCTAssertEqual(model.name, "X")
        XCTAssertThrowsError(try HorizontalPoolItemModel.load(json: ["type": "pool", "uuid": "p"]))
    }

    // MARK: - Stock pool sweep

    /// Every stock pool item, through its model and back, must reproduce the
    /// dictionary the file parsed to — which the writer then turns back into
    /// the file's own bytes.
    func testStockPoolItemsRoundTripThroughTheirModels() throws {
        let poolURL = URL(fileURLWithPath: "/Users/kornack/Repositories/horizon-pool", isDirectory: true)
        guard FileManager.default.fileExists(atPath: poolURL.appendingPathComponent("pool.json").path) else {
            throw XCTSkip("stock horizon-pool checkout not available")
        }
        let items = HorizontalPoolLibrary.items(inPool: poolURL, poolName: "stock")
        XCTAssertGreaterThan(items.count, 1_000)

        var failures = [String]()
        var counts = [HorizontalPoolItemCategory: Int]()
        for item in items {
            let json = try JSONHelper.loadDictionary(from: item.url)
            let relative = item.url.path.dropFirst(poolURL.path.count + 1)
            do {
                let model = try HorizontalPoolItemModel.load(category: item.category, json: json)
                let written = model.json()
                let expected = try HorizontalHorizonJSONWriter.string(json)
                let actual = try HorizontalHorizonJSONWriter.string(written)
                if expected != actual {
                    failures.append("\(relative): \(Self.firstDifference(expected, actual))")
                }
                counts[item.category, default: 0] += 1
            } catch {
                failures.append("\(relative): \(error)")
            }
        }
        // Files upstream's own re-save rewrites the same way: a derived part
        // that also carries entity/package (Horizon writes only `base`), a
        // placement angle outside 0..65535 (Horizon wraps it), and a symbol
        // stamped `version: 1` without any text placements (Horizon recomputes
        // the version from content).
        let knownUpstreamRewrites: Set<String> = [
            "parts/ic/regulator/ti/LP5907MFX-3.3-NOPB.json",
            "packages/ic/smd/soic/so-20/package.json",
            "symbols/ic/mcu/stm/STM32L15xCxTx.json",
        ]
        let unexpected = failures.filter { failure in
            !knownUpstreamRewrites.contains { failure.hasPrefix($0 + ":") }
        }
        XCTAssertEqual(unexpected.prefix(20).map { $0 }, [], "\(unexpected.count) of \(items.count) items changed through their model")
        XCTAssertEqual(failures.count, knownUpstreamRewrites.count, "the known rewrites should still be the only ones")
        print("[models] round-tripped \(counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))")
    }

    private static func firstDifference(_ a: String, _ b: String) -> String {
        let aChars = Array(a), bChars = Array(b)
        let index = zip(aChars, bChars).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(aChars.count, bChars.count)
        let start = max(0, index - 40)
        func excerpt(_ chars: [Character]) -> String {
            String(chars[start..<min(chars.count, index + 40)]).replacingOccurrences(of: "\n", with: "⏎")
        }
        return "at \(index): source …\(excerpt(aChars))… model …\(excerpt(bChars))…"
    }
}
