import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The logic behind the unit, entity and part form editors that doesn't need
/// a window: alternate-name parsing, gate suffix generation, and the part
/// editor's view of its entity, package and base chain.
final class HorizontalPoolFormEditorTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolFormEditorTests-\(UUID().uuidString)", isDirectory: true)
        HorizontalPoolLibrary.invalidateCache()
    }

    override func tearDownWithError() throws {
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private func write(_ json: JSONDictionary, to relativePath: String) throws {
        let url = temporaryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(json).write(to: url)
    }

    // MARK: - Unit editor

    func testAlternateNamesKeepExistingIDsAndSeedNewOnesWithThePinDirection() {
        let existing = [
            HorizontalUnitPinAlternateName(id: "a", name: "TX", direction: .output),
            HorizontalUnitPinAlternateName(id: "b", name: "RX", direction: .input),
        ]
        let parsed = HorizontalUnitEditorView.alternateNames(from: " RX, SCL ,, TX ", keeping: existing, direction: .bidirectional)
        XCTAssertEqual(Set(parsed.map(\.name)), ["RX", "SCL", "TX"])
        XCTAssertEqual(parsed.first { $0.name == "TX" }?.id, "a")
        XCTAssertEqual(parsed.first { $0.name == "TX" }?.direction, .output)
        XCTAssertEqual(parsed.first { $0.name == "SCL" }?.direction, .bidirectional)
        XCTAssertEqual(HorizontalUnitEditorView.alternateNames(from: "", keeping: existing, direction: .input), [])
    }

    // MARK: - Entity editor

    func testNextGateSuffixSkipsTakenLetters() {
        XCTAssertEqual(HorizontalEntityEditorView.nextSuffix(after: []), "A")
        XCTAssertEqual(HorizontalEntityEditorView.nextSuffix(after: ["A", "B"]), "C")
        XCTAssertEqual(HorizontalEntityEditorView.nextSuffix(after: ["A", "C"]), "B")
        let all = (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) }
        XCTAssertEqual(HorizontalEntityEditorView.nextSuffix(after: all), "AA")
    }

    // MARK: - Part editor context

    private func writeFixturePool() throws -> HorizontalPoolLibraryIndex {
        try write(["type": "pool", "uuid": "pool", "name": "Fixture"], to: "pool.json")
        try write([
            "type": "unit", "uuid": "unit-a", "name": "Op-amp",
            "pins": [
                "pin-in": ["primary_name": "IN", "direction": "input"],
                "pin-out": ["primary_name": "OUT", "direction": "output"],
            ],
        ], to: "units/opamp.json")
        try write([
            "type": "entity", "uuid": "ent-1", "name": "Dual op-amp", "prefix": "U", "tags": ["opamp"],
            "gates": [
                "gate-b": ["name": "B", "suffix": "B", "swap_group": 1, "unit": "unit-a"],
                "gate-a": ["name": "A", "suffix": "A", "swap_group": 1, "unit": "unit-a"],
            ],
        ], to: "entities/dual.json")
        try write(["type": "padstack", "uuid": "ps-smd", "name": "SMD", "padstack_type": "top"], to: "padstacks/smd.json")
        try write(["type": "padstack", "uuid": "ps-mech", "name": "Mounting", "padstack_type": "mechanical"], to: "padstacks/mech.json")
        let placement: JSONDictionary = ["shift": [0, 0], "angle": 0, "mirror": false]
        try write([
            "type": "package", "uuid": "pkg-1", "name": "SO-8",
            "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:],
            "pads": [
                "pad-1": ["name": "1", "padstack": "ps-smd", "placement": placement, "parameter_set": [:]],
                "pad-2": ["name": "2", "padstack": "ps-smd", "placement": placement, "parameter_set": [:]],
                "pad-m": ["name": "M", "padstack": "ps-mech", "placement": placement, "parameter_set": [:]],
            ],
            "models": ["m-1": ["filename": "3d_models/so8.step", "x": 0, "y": 0, "z": 0, "roll": 0, "pitch": 0, "yaw": 0]],
            "default_model": "m-1",
        ], to: "packages/so8/package.json")
        try write([
            "type": "part", "uuid": "part-base",
            "MPN": [false, "BASE-1"], "value": [false, ""], "manufacturer": [false, "Acme"],
            "description": [false, "Base description"], "datasheet": [false, "https://example.com/base.pdf"],
            "tags": ["base-tag"], "entity": "ent-1", "package": "pkg-1",
            "pad_map": ["pad-1": ["gate": "gate-a", "pin": "pin-in"]],
            "model": "m-1", "inherit_model": true,
        ], to: "parts/base.json")
        try write([
            "type": "part", "uuid": "part-derived",
            "MPN": [false, "DERIVED-1"], "value": [true, ""], "manufacturer": [true, ""],
            "description": [true, ""], "datasheet": [true, ""],
            "tags": ["own-tag"], "inherit_tags": true, "base": "part-base",
        ], to: "parts/derived.json")
        let items = HorizontalPoolLibrary.items(inPool: temporaryRoot, poolName: "Fixture")
        return HorizontalPoolLibraryIndex(items: items)
    }

    func testPartContextListsGatePinsAndNonMechanicalPads() throws {
        let index = try writeFixturePool()
        let context = HorizontalPartEditorContext.load(entityID: "ent-1", packageID: "pkg-1", baseID: nil, index: index)
        XCTAssertEqual(context.entityName, "Dual op-amp")
        XCTAssertEqual(context.packageName, "SO-8")
        XCTAssertEqual(context.pins.map(\.displayName), ["A.IN", "A.OUT", "B.IN", "B.OUT"])
        XCTAssertEqual(context.pads.map(\.name), ["1", "2"], "the mechanical pad is not mappable")
        XCTAssertEqual(context.models.map(\.filename), ["3d_models/so8.step"])
        XCTAssertEqual(context.defaultModelID, "m-1")
        XCTAssertNil(context.baseName)
    }

    func testPartContextResolvesTheBaseChain() throws {
        let index = try writeFixturePool()
        let context = HorizontalPartEditorContext.load(entityID: nil, packageID: nil, baseID: "part-base", index: index)
        XCTAssertEqual(context.baseName, "BASE-1")
        XCTAssertEqual(context.entityID, "ent-1")
        XCTAssertEqual(context.packageID, "pkg-1")
        XCTAssertEqual(context.baseAttributes[.manufacturer], "Acme")
        XCTAssertEqual(context.baseAttributes[.description], "Base description")
        XCTAssertEqual(context.baseTags, ["base-tag"])
        XCTAssertEqual(context.baseModelID, "m-1")
        XCTAssertEqual(context.basePadMap["pad-1"], HorizontalPartPadMapEntry(gateID: "gate-a", pinID: "pin-in"))
        XCTAssertEqual(context.pins.count, 4, "pins come from the base's entity")
    }

    func testDerivedPartLoadsWithInheritedAttributes() throws {
        let index = try writeFixturePool()
        let json = try XCTUnwrap(index.json(.part, uuid: "part-derived"))
        let part = try HorizontalPoolPartItem(json: json)
        XCTAssertEqual(part.baseID, "part-base")
        XCTAssertTrue(part.attribute(.manufacturer).inherited)
        XCTAssertTrue(part.inheritTags)
        XCTAssertEqual(part.name, "DERIVED-1")
        XCTAssertTrue(NSDictionary(dictionary: part.json()).isEqual(to: json))
    }
}

// MARK: - Completions and tokens

extension HorizontalPoolFormEditorTests {
    func testIndexCollectsManufacturersAndTagsForCompletions() {
        func item(_ uuid: String, category: HorizontalPoolItemCategory, tags: String, manufacturer: String) -> HorizontalPoolLibraryItem {
            HorizontalPoolLibraryItem(
                id: "p|\(category.rawValue)|\(uuid)", uuid: uuid, name: uuid, detail: "", tags: tags,
                category: category, poolName: "p", poolURL: URL(fileURLWithPath: "/p"),
                url: URL(fileURLWithPath: "/p/\(uuid).json"), manufacturer: manufacturer
            )
        }
        let index = HorizontalPoolLibraryIndex(items: [
            item("a", category: .part, tags: "resistor smd", manufacturer: "Yageo"),
            item("b", category: .package, tags: "smd 0603", manufacturer: " "),
            item("c", category: .unit, tags: "", manufacturer: "Texas Instruments"),
            item("d", category: .entity, tags: "opamp", manufacturer: "yageo"),
        ])
        XCTAssertEqual(index.manufacturers, ["Texas Instruments", "Yageo"], "case variants fold to the first spelling")
        XCTAssertEqual(index.tags, ["0603", "opamp", "resistor", "smd"])
    }

    func testSuggestionMatchingPrefersPrefixesAndSkipsExisting() {
        let suggestions = ["Texas Instruments", "Yageo", "Vishay", "STMicroelectronics", "Microchip", "TE Connectivity"]
        XCTAssertEqual(
            HorizontalSuggestionMatcher.matches(for: "te", in: suggestions, excluding: []),
            ["Texas Instruments", "TE Connectivity"]
        )
        XCTAssertEqual(
            HorizontalSuggestionMatcher.matches(for: "micro", in: suggestions, excluding: []),
            ["Microchip", "STMicroelectronics"],
            "prefix matches first, then substring matches"
        )
        XCTAssertEqual(HorizontalSuggestionMatcher.matches(for: "yageo", in: suggestions, excluding: []), [], "an exact match needs no suggestion")
        XCTAssertEqual(HorizontalSuggestionMatcher.matches(for: "v", in: suggestions, excluding: ["Vishay"]), ["TE Connectivity"])
        XCTAssertEqual(HorizontalSuggestionMatcher.matches(for: "  ", in: suggestions, excluding: []), [])
        let many = (0..<20).map { "tag\($0)" }
        XCTAssertEqual(HorizontalSuggestionMatcher.matches(for: "tag", in: many, excluding: []).count, 8, "capped")
    }

    func testTokenFieldSplitsOnSeparators() {
        XCTAssertEqual(HorizontalTokenField.tokens(splitting: "resistor, smd;0603 thin-film"), ["resistor", "smd", "0603", "thin-film"])
        XCTAssertEqual(HorizontalTokenField.tokens(splitting: "   "), [])
    }
}
