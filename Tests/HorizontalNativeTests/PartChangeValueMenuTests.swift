import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A symbol's Change Value submenu: the parts for the component's entity of
/// every other value, so a 10 kΩ resistor is offered the 22 kΩ and the
/// 4.7 kΩ, in whatever footprint. With Option held the menu shows the same
/// list kept to the footprint the component has now.
final class PartChangeValueMenuTests: XCTestCase {
    private let projectPool = URL(fileURLWithPath: "/change-value/project/pool")
    private let stockPool = URL(fileURLWithPath: "/change-value/stock")

    private func part(_ uuid: String, mpn: String, value: String, entity: String = "e-res", package: String,
                      in pool: URL, isBasePart: Bool = false) -> HorizontalPoolLibraryItem {
        HorizontalPoolLibraryItem(
            id: pool.path + "|part|\(uuid)", uuid: uuid, name: mpn, detail: "Yageo", tags: "", category: .part,
            poolName: pool == projectPool ? "Project pool" : "Stock", poolURL: pool,
            url: pool.appendingPathComponent("parts/\(uuid).json"), manufacturer: "Yageo", value: value,
            partDescription: "", mpn: mpn, parametric: [:], packageID: package, isBasePart: isBasePart,
            partEntityID: entity
        )
    }

    private func package(_ uuid: String, name: String) -> HorizontalPoolLibraryItem {
        HorizontalPoolLibraryItem(
            id: stockPool.path + "|package|\(uuid)", uuid: uuid, name: name, detail: "", tags: "", category: .package,
            poolName: "Stock", poolURL: stockPool, url: stockPool.appendingPathComponent("packages/\(uuid)/package.json")
        )
    }

    private var catalog: HorizontalPartAlternatesCatalog {
        HorizontalPartAlternatesCatalog(items: [
            part("p-10k-0603", mpn: "RC0603-10K", value: "10 kΩ", package: "pkg-0603", in: projectPool),
            part("p-22k-0603", mpn: "RC0603-22K", value: "22 kΩ", package: "pkg-0603", in: projectPool),
            part("p-10k-0402", mpn: "RC0402-10K", value: "10k", package: "pkg-0402", in: stockPool),
            part("p-22k-0402", mpn: "RC0402-22K", value: "22k", package: "pkg-0402", in: stockPool),
            part("p-4k7-0402", mpn: "RC0402-4K7", value: "4.7 kΩ", package: "pkg-0402", in: stockPool),
            part("p-1r-0603", mpn: "RC0603-1R", value: "1 Ω", package: "pkg-0603", in: stockPool),
            part("p-series", mpn: "RC0603", value: "47k", package: "pkg-0603", in: stockPool, isBasePart: true),
            part("p-generic", mpn: "Generic resistor", value: "", package: "pkg-0603", in: stockPool),
            part("p-100n", mpn: "CL10B104", value: "100 nF", entity: "e-cap", package: "pkg-0603", in: projectPool),
            package("pkg-0402", name: "0402"), package("pkg-0603", name: "0603"),
        ], projectPoolURL: projectPool)
    }

    private var block: JSONDictionary {
        ["components": [
            "c-r1": ["refdes": "R1", "entity": "e-res", "part": "p-10k-0603", "value": ""],
            "c-r2": ["refdes": "R2", "entity": "e-res", "part": "p-22k-0603", "value": ""],
            "c-r3": ["refdes": "R3", "entity": "e-res", "part": "p-10k-0402", "value": ""],
            "c-r4": ["refdes": "R4", "entity": "e-res", "value": "10K"],
            "c-c1": ["refdes": "C1", "entity": "e-cap", "part": "p-100n", "value": ""],
        ] as JSONDictionary]
    }

    private func replacement(_ componentIDs: Set<String>) -> HorizontalPartReplacement? {
        HorizontalPartReplacement(componentIDs: componentIDs, block: block)
    }

    private func values(_ componentIDs: Set<String>, samePackage: Bool) -> HorizontalPartValuesOffer? {
        replacement(componentIDs).flatMap { catalog.values(for: $0, samePackage: samePackage) }
    }

    private func parts(_ offer: HorizontalPartValuesOffer?) -> [[String]] {
        (offer?.values ?? []).map { $0.parts.map(\.uuid) }
    }

    func testAResistorIsOfferedEveryOtherValueOfItsEntityRisingWithItsOwnFootprintFirst() throws {
        let offer = try XCTUnwrap(values(["c-r1"], samePackage: false))
        XCTAssertEqual(offer.values.map(\.text), ["1 Ω", "4.7 kΩ", "22 kΩ"], "not 10 kΩ, which it has; no base part, none with no value")
        XCTAssertEqual(parts(offer), [["p-1r-0603"], ["p-4k7-0402"], ["p-22k-0603", "p-22k-0402"]],
                       "22 kΩ and 22k are one value; the 0603 it is in comes first")
    }

    func testWithTheSameFootprintOnlyPartsInThePackageItHasAreOffered() throws {
        XCTAssertEqual(parts(values(["c-r1"], samePackage: true)), [["p-1r-0603"], ["p-22k-0603"]])
        XCTAssertEqual(parts(values(["c-r3"], samePackage: true)), [["p-4k7-0402"], ["p-22k-0402"]])
    }

    func testAComponentWithNoPartHasNoFootprintToKeepButIsOfferedValues() throws {
        XCTAssertNil(values(["c-r4"], samePackage: true))
        XCTAssertEqual(try XCTUnwrap(values(["c-r4"], samePackage: false)).values.map(\.text), ["1 Ω", "4.7 kΩ", "22k"],
                       "the 10K it stores is the value it has; with no footprint of its own, a value is written as its first package's part writes it")
    }

    func testSeveralComponentsAreOfferedEveryValueTheyDoNotAllHave() throws {
        let both = try XCTUnwrap(values(["c-r1", "c-r2"], samePackage: true))
        XCTAssertEqual(both.values.map(\.text), ["1 Ω", "10 kΩ", "22 kΩ"], "each is a change for one of them")
        XCTAssertNil(values(["c-r1", "c-r3"], samePackage: true), "two footprints: none to keep")
        XCTAssertNotNil(values(["c-r1", "c-r3"], samePackage: false))
        XCTAssertNil(values(["c-r1", "c-c1"], samePackage: false), "two entities")
    }

    func testTheSubmenuNamesAValuesPartOrListsItsPartsUnderIt() throws {
        let content = HorizontalPartReplaceMenu.valueContent(for: try XCTUnwrap(values(["c-r1"], samePackage: false)))
        XCTAssertEqual(content.title, "Change Value")
        guard case .choice(let title, let badge, _, let isOn, .replacePart(let part, let components)) = content.entries[0] else {
            return XCTFail("a value one part has is a choice")
        }
        XCTAssertEqual(title, "1 Ω · 0603 · RC0603-1R · Yageo")
        XCTAssertNil(badge)
        XCTAssertFalse(isOn)
        XCTAssertEqual(part, "p-1r-0603")
        XCTAssertEqual(components, ["c-r1"])
        guard case .submenu(let value, let choices) = content.entries[2] else {
            return XCTFail("a value several parts have is a submenu of them")
        }
        XCTAssertEqual(value, "22 kΩ")
        XCTAssertEqual(choices.count, 2)
        guard case .choice(let first, let firstBadge, _, _, _) = choices[0] else {
            return XCTFail("its parts are choices")
        }
        XCTAssertEqual(first, "0603 · RC0603-22K · Yageo")
        XCTAssertEqual(firstBadge, HorizontalPartReplaceMenu.inProjectBadge)

        let kept = HorizontalPartReplaceMenu.valueContent(for: try XCTUnwrap(values(["c-r1", "c-r2"], samePackage: true)))
        XCTAssertEqual(kept.title, "Change Value, Same Footprint of R1, R2")
        guard case .choice(let keptTitle, _, _, _, .replacePart(_, let keptComponents)) = kept.entries[0] else {
            return XCTFail("a choice")
        }
        XCTAssertEqual(keptTitle, "1 Ω · RC0603-1R · Yageo", "the footprint they all have is not said")
        XCTAssertEqual(keptComponents, ["c-r1", "c-r2"])
    }

    func testALongListGoesUnderItsDecades() throws {
        let content = HorizontalPartReplaceMenu.valueContent(
            for: try XCTUnwrap(values(["c-r1"], samePackage: false)), groupLimit: 2)
        let titles = content.entries.map { entry -> String in
            if case .submenu(let title, _) = entry { return title }
            return "?"
        }
        XCTAssertEqual(titles, ["1 Ω", "4.7 kΩ", "22 kΩ"], "one value in each of three decades")
    }

    func testOptionShowsTheSameFootprintListWhereThereIsOneAndNoOtherValuesSaysSo() throws {
        let entry = try XCTUnwrap(HorizontalPartReplaceMenu.valueEntry(
            catalog: catalog, componentID: "c-r1", selection: [], replacement: replacement))
        guard case .optionAlternate(.submenu(let usual, _), .submenu(let withOption, _)) = entry else {
            return XCTFail("two submenus, the second for Option")
        }
        XCTAssertEqual(usual, "Change Value")
        XCTAssertEqual(withOption, "Change Value, Same Footprint")

        let noPart = try XCTUnwrap(HorizontalPartReplaceMenu.valueEntry(
            catalog: catalog, componentID: "c-r4", selection: [], replacement: replacement))
        guard case .submenu = noPart else {
            return XCTFail("no footprint to keep: the one submenu")
        }

        let capacitor = try XCTUnwrap(HorizontalPartReplaceMenu.valueEntry(
            catalog: catalog, componentID: "c-c1", selection: [], replacement: replacement))
        guard case .optionAlternate(.submenu(_, let entries), _) = capacitor,
              case .unavailable(let title, _) = entries[0] else {
            return XCTFail("the only capacitor has no other value")
        }
        XCTAssertEqual(title, "No Other Values")
    }
}
