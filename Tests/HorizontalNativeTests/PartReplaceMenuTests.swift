import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A symbol's or package's Replace submenu: the parts for the component's
/// entity and of its value, in whatever package, so a 10 kΩ 0603 resistor is
/// offered the 10 kΩ 0402. Each says whether the project pool already holds
/// it, the part the component has is checked, and several components
/// right-clicked together are replaced together where one list answers them.
final class PartReplaceMenuTests: XCTestCase {
    private let projectPool = URL(fileURLWithPath: "/replace-menu/project/pool")
    private let stockPool = URL(fileURLWithPath: "/replace-menu/stock")

    private func part(_ uuid: String, mpn: String, value: String, entity: String = "e-res", package: String,
                      in pool: URL, parametric: [String: String] = [:], isBasePart: Bool = false,
                      manufacturer: String = "Yageo", description: String = "") -> HorizontalPoolLibraryItem {
        HorizontalPoolLibraryItem(
            id: pool.path + "|part|\(uuid)", uuid: uuid, name: mpn, detail: manufacturer, tags: "", category: .part,
            poolName: pool == projectPool ? "Project pool" : "Stock", poolURL: pool,
            url: pool.appendingPathComponent("parts/\(uuid).json"), manufacturer: manufacturer, value: value,
            partDescription: description, mpn: mpn, parametric: parametric, packageID: package, isBasePart: isBasePart,
            partEntityID: entity
        )
    }

    private func package(_ uuid: String, name: String) -> HorizontalPoolLibraryItem {
        HorizontalPoolLibraryItem(
            id: stockPool.path + "|package|\(uuid)", uuid: uuid, name: name, detail: "", tags: "", category: .package,
            poolName: "Stock", poolURL: stockPool, url: stockPool.appendingPathComponent("packages/\(uuid)/package.json")
        )
    }

    /// The pools as a scan gives them, the project pool's items first: 10 kΩ
    /// in three packages, the 0603 and the 0402 already in the project.
    private var catalog: HorizontalPartAlternatesCatalog {
        let resistors = ["table": "resistors", "value": "10000"]
        return HorizontalPartAlternatesCatalog(items: [
            part("p-10k-0603", mpn: "RC0603-10K", value: "10 kΩ", package: "pkg-0603", in: projectPool, parametric: resistors),
            part("p-10k-0402", mpn: "RC0402-10K", value: "10 kΩ", package: "pkg-0402", in: projectPool, parametric: resistors),
            part("p-22k-0603", mpn: "RC0603-22K", value: "22 kΩ", package: "pkg-0603", in: projectPool),
            part("p-100n", mpn: "CL10B104", value: "100 nF", entity: "e-cap", package: "pkg-0603", in: projectPool),
            part("p-10k-0402", mpn: "RC0402-10K", value: "10 kΩ", package: "pkg-0402", in: stockPool, parametric: resistors),
            part("p-10k-0805", mpn: "CPL-RES-0805-10K", value: "10k", package: "pkg-0805", in: stockPool, manufacturer: "CPL",
                 description: "Thick film, 1 %, 0.125 W"),
            part("p-22k-0402", mpn: "RC0402-22K", value: "22 kΩ", package: "pkg-0402", in: stockPool),
            part("p-10k-series", mpn: "RC0603", value: "10k", package: "pkg-0603", in: stockPool, isBasePart: true),
            part("p-generic", mpn: "base 0603 resistor", value: "", package: "pkg-0603", in: stockPool),
            part("p-10k-cap", mpn: "Odd", value: "10k", entity: "e-cap", package: "pkg-0402", in: stockPool),
            part("p-ams1117", mpn: "AMS1117-3.3", value: "", entity: "e-reg", package: "pkg-sot223", in: projectPool),
            part("p-ncp1117", mpn: "NCP1117ST33", value: "", entity: "e-reg", package: "pkg-dpak", in: stockPool),
            package("pkg-0402", name: "0402"), package("pkg-0603", name: "0603"), package("pkg-0805", name: "0805"),
            package("pkg-sot223", name: "SOT-223"), package("pkg-dpak", name: "DPAK"),
        ], projectPoolURL: projectPool)
    }

    private var block: JSONDictionary {
        ["components": [
            "c-r1": ["refdes": "R1", "entity": "e-res", "part": "p-10k-0603", "value": ""],
            "c-r2": ["refdes": "R2", "entity": "e-res", "part": "p-10k-0603", "value": ""],
            "c-r3": ["refdes": "R3", "entity": "e-res", "part": "p-22k-0603", "value": ""],
            "c-r4": ["refdes": "R4", "entity": "e-res", "value": "10K"],
            "c-c1": ["refdes": "C1", "entity": "e-cap", "part": "p-100n", "value": ""],
            "c-u1": ["refdes": "U1", "entity": "e-reg", "part": "p-ams1117", "value": ""],
        ] as JSONDictionary]
    }

    private func replacement(_ componentIDs: Set<String>) -> HorizontalPartReplacement? {
        HorizontalPartReplacement(componentIDs: componentIDs, block: block)
    }

    private func offer(_ componentIDs: Set<String>) -> HorizontalPartAlternatesOffer? {
        replacement(componentIDs).flatMap(catalog.offer)
    }

    private struct Choice: Equatable {
        var title: String
        var badge: String?
        var isOn: Bool
        var part: String
        var components: [String]
    }

    private func choices(_ entries: [HorizontalTargetItemMenuEntry]) -> [Choice] {
        entries.compactMap { entry in
            guard case .choice(let title, let badge, _, let isOn, .replacePart(let part, let components)) = entry else {
                return nil
            }
            return Choice(title: title, badge: badge, isOn: isOn, part: part, components: components)
        }
    }

    // MARK: - Values

    func testAValueIsWhatItIsHoweverItIsWritten() {
        let tenK = HorizontalPartValue("10 kΩ", parametric: ["table": "resistors", "value": "10000"])
        for same in ["10k", "10K", "10 kΩ", "10k0", "10 kOhm", " 10000 "] {
            XCTAssertTrue(tenK.matches(HorizontalPartValue(same)), same)
            XCTAssertTrue(HorizontalPartValue(same).matches(tenK), same)
        }
        for other in ["22k", "10", "10M", "10m", "", "LM358"] {
            XCTAssertFalse(tenK.matches(HorizontalPartValue(other)), other)
        }
        // The table's number is the value, whatever the text says.
        XCTAssertTrue(HorizontalPartValue("", parametric: ["value": "1e4"]).matches(tenK))
        XCTAssertTrue(HorizontalPartValue("100n").matches(HorizontalPartValue("0.1 µF")), "one number, to nine digits")
        XCTAssertTrue(HorizontalPartValue("4k7").matches(HorizontalPartValue("4.7 kΩ")))
        XCTAssertTrue(HorizontalPartValue("0R").matches(HorizontalPartValue("0 Ω")))

        // What is no number is its text, whatever its case and spacing.
        XCTAssertTrue(HorizontalPartValue("LM358").matches(HorizontalPartValue(" lm358 ")))
        XCTAssertTrue(HorizontalPartValue("8 MHz").matches(HorizontalPartValue("8MHz")))
        XCTAssertFalse(HorizontalPartValue("LM358").matches(HorizontalPartValue("TL072")))
        // No value matches only no value.
        XCTAssertTrue(HorizontalPartValue("").matches(HorizontalPartValue("  ")))
        XCTAssertFalse(HorizontalPartValue("").matches(HorizontalPartValue("LM358")))
    }

    // MARK: - The parts offered

    func testAResistorIsOfferedThePartsOfItsValueInEveryPackage() throws {
        let offer = try XCTUnwrap(offer(["c-r1"]))
        XCTAssertEqual(offer.parts.map(\.uuid), ["p-10k-0402", "p-10k-0603", "p-10k-0805"],
                       "by package; not the 22 kΩ, the capacitor entity's 10k, the valueless part or the base part")
        XCTAssertEqual(offer.parts.map(\.isInProjectPool), [true, true, false], "a part both pools hold is the project's")
        XCTAssertEqual(offer.parts.map(\.packageName), ["0402", "0603", "0805"])
        XCTAssertEqual(offer.parts.map(offer.isCurrent), [false, true, false])
        XCTAssertEqual(offer.others.map(\.uuid), ["p-10k-0402", "p-10k-0805"])
        XCTAssertEqual(offer.value, "10 kΩ")
        // Replace takes the project pool's copy of a part both pools hold.
        XCTAssertEqual(offer.parts.first?.item.poolURL, projectPool)
    }

    func testAComponentWithNoPartIsOfferedThePartsOfTheValueItStores() throws {
        let offer = try XCTUnwrap(offer(["c-r4"]))
        XCTAssertEqual(offer.parts.map(\.uuid), ["p-10k-0402", "p-10k-0603", "p-10k-0805"])
        XCTAssertEqual(offer.parts.map(offer.isCurrent), [false, false, false])
        XCTAssertEqual(offer.value, "10K")
    }

    func testAPartWithNoValueIsOfferedItsEntitysOtherPartsWithNone() throws {
        let offer = try XCTUnwrap(offer(["c-u1"]))
        XCTAssertEqual(offer.parts.map(\.uuid), ["p-ncp1117", "p-ams1117"], "DPAK before SOT-223")
        XCTAssertEqual(offer.value, "")
    }

    func testComponentsAreOfferedOneListOnlyWhereTheyShareAnEntityAndAValue() throws {
        XCTAssertEqual(try XCTUnwrap(offer(["c-r1", "c-r2"])).replacement.targets.map(\.refdes), ["R1", "R2"])
        XCTAssertEqual(try XCTUnwrap(offer(["c-r1", "c-r4"])).parts.count, 3, "10 kΩ by part and 10K by hand are one value")
        XCTAssertNil(offer(["c-r1", "c-r3"]), "10 kΩ and 22 kΩ")
        XCTAssertNil(offer(["c-r1", "c-c1"]), "two entities")
    }

    // MARK: - The submenu

    func testTheSubmenuListsEachPartByItsPackageBadgesTheProjectsAndChecksTheOneInUse() throws {
        let content = HorizontalPartReplaceMenu.content(for: try XCTUnwrap(offer(["c-r1"])))
        XCTAssertEqual(content.title, "Replace")
        XCTAssertEqual(choices(content.entries), [
            Choice(title: "0402 · RC0402-10K · Yageo", badge: "In Project", isOn: false, part: "p-10k-0402", components: ["c-r1"]),
            Choice(title: "0603 · RC0603-10K · Yageo", badge: "In Project", isOn: true, part: "p-10k-0603", components: ["c-r1"]),
            Choice(title: "0805 · CPL-RES-0805-10K · CPL", badge: nil, isOn: false, part: "p-10k-0805", components: ["c-r1"]),
        ])
        XCTAssertEqual(content.entries.count, 3)
        guard case .choice(_, _, let help?, _, _) = content.entries[2] else {
            return XCTFail("the 0805 has help")
        }
        XCTAssertEqual(help, "Thick film, 1 %, 0.125 W\nFrom Stock. Replace copies it into the project pool.")
        guard case .choice(_, _, let inProject?, _, _) = content.entries[0] else {
            return XCTFail("the 0402 has help")
        }
        XCTAssertEqual(inProject, "Already in the project pool.")
    }

    func testAPackageNamedForItsPartIsNotSaidTwice() throws {
        let catalog = HorizontalPartAlternatesCatalog(items: [
            part("p-sma", mpn: "142-0761-881", value: "", entity: "e-coax", package: "pkg-sma", in: stockPool, manufacturer: "Cinch"),
            part("p-bare", mpn: "Test point", value: "", entity: "e-coax", package: "", in: stockPool, manufacturer: ""),
            package("pkg-sma", name: "142-0761-881"),
        ], projectPoolURL: projectPool)
        XCTAssertEqual(HorizontalPartReplaceMenu.title(of: try XCTUnwrap(catalog.part("p-sma"))), "142-0761-881 · Cinch")
        XCTAssertEqual(HorizontalPartReplaceMenu.title(of: try XCTUnwrap(catalog.part("P-BARE"))), "Test point")
    }

    func testAComponentWithNoAlternateSaysSo() throws {
        let content = HorizontalPartReplaceMenu.content(for: try XCTUnwrap(offer(["c-c1"])))
        guard case .unavailable(let title, let reason) = try XCTUnwrap(content.entries.first), content.entries.count == 1 else {
            return XCTFail("one dimmed item")
        }
        XCTAssertEqual(title, "No Other Parts")
        XCTAssertEqual(reason, "No pool this project draws on has another part for the same entity with the value “100 nF”.")
    }

    func testALongListKeepsThePartInUseAndTheProjectsAndSaysHowManyMore() throws {
        let content = HorizontalPartReplaceMenu.content(for: try XCTUnwrap(offer(["c-r4"])), limit: 2)
        XCTAssertEqual(choices(content.entries).map(\.part), ["p-10k-0402", "p-10k-0603"], "the project pool's two")
        guard case .unavailable(let title, _) = try XCTUnwrap(content.entries.last) else {
            return XCTFail("a count of the rest")
        }
        XCTAssertEqual(title, "1 More…")
    }

    func testARightClickAmongASelectionReplacesItWhereOneListAnswersIt() throws {
        func content(_ componentID: String, _ selection: Set<String>) -> HorizontalPartReplaceMenu.Content? {
            HorizontalPartReplaceMenu.content(catalog: catalog, componentID: componentID, selection: selection,
                                              replacement: replacement)
        }
        let together = try XCTUnwrap(content("c-r1", ["c-r1", "c-r2", "c-r4"]))
        XCTAssertEqual(together.title, "Replace R1, R2, R4")
        XCTAssertEqual(choices(together.entries).first?.components, ["c-r1", "c-r2", "c-r4"])
        XCTAssertEqual(choices(together.entries).map(\.isOn), [false, false, false], "R4 has no part, so none is every one's")

        // Different values: the one right-clicked alone.
        let alone = try XCTUnwrap(content("c-r1", ["c-r1", "c-r3"]))
        XCTAssertEqual(alone.title, "Replace")
        XCTAssertEqual(choices(alone.entries).first?.components, ["c-r1"])
        // Right-clicked outside the selection: itself alone.
        XCTAssertEqual(choices(try XCTUnwrap(content("c-r1", [])).entries).first?.components, ["c-r1"])
        XCTAssertNil(content("c-missing", []), "a component no block has")
    }

    // MARK: - A part's row in the Parts pane

    func testAPartsRowOffersReplaceAndChangeValueForEveryComponentFittedWithIt() throws {
        let entries = HorizontalPartReplaceMenu.rowEntries(catalog: catalog, componentIDs: ["c-r1", "c-r2"], replacement: replacement)
        XCTAssertEqual(entries.count, 2)
        guard case .submenu(let replaceTitle, let parts) = entries[0] else {
            return XCTFail("Replace")
        }
        XCTAssertEqual(replaceTitle, "Replace R1, R2")
        XCTAssertEqual(choices(parts).map(\.part), ["p-10k-0402", "p-10k-0603", "p-10k-0805"])
        XCTAssertEqual(choices(parts).map(\.isOn), [false, true, false], "the part the row is for")
        XCTAssertEqual(Set(choices(parts).map(\.components)), [["c-r1", "c-r2"]])
        // Change Value, and with Option held the same in the footprint.
        guard case .optionAlternate(.submenu(let anyTitle, _), .submenu(let sameTitle, _)) = entries[1] else {
            return XCTFail("Change Value and its Option alternate")
        }
        XCTAssertEqual(anyTitle, "Change Value of R1, R2")
        XCTAssertEqual(sameTitle, "Change Value, Same Footprint of R1, R2")
    }

    func testAPartsRowOffersNothingForComponentsNoOneBlockHas() {
        XCTAssertTrue(HorizontalPartReplaceMenu.rowEntries(catalog: catalog, componentIDs: ["c-r1", "c-elsewhere"],
                                                           replacement: replacement).isEmpty,
                      "one of them is in another block: a list for R1 alone would not be the row's")
        XCTAssertTrue(HorizontalPartReplaceMenu.rowEntries(catalog: catalog, componentIDs: ["c-missing"], replacement: replacement).isEmpty)
    }

    func testAPartsUsesAreGroupedByBlockTheTopBlockFirst() {
        let blocks = [
            HorizontalProjectBlock(uuid: "B-TOP", isTop: true, name: "Main"),
            HorizontalProjectBlock(uuid: "b-amp", isTop: false, name: "Amplifier"),
            HorizontalProjectBlock(uuid: "b-adc", isTop: false, name: "ADC"),
        ]
        let components: [(id: String, partID: String?, blockID: String?)] = [
            ("C-R1", "P-10K", nil), ("c-r2", "p-10k", "b-top"), ("c-r3", "p-10k", "B-AMP"), ("c-r4", "p-10k", "b-adc"),
            ("c-r5", "p-22k", nil), ("c-r6", nil, nil),
        ]
        let groups = HorizontalPartUseGroup.groups(usingPart: "p-10k", components: components, blocks: blocks)
        XCTAssertEqual(groups.map(\.blockName), ["Main", "ADC", "Amplifier"])
        XCTAssertEqual(groups.map(\.componentIDs), [["c-r1", "c-r2"], ["c-r4"], ["c-r3"]])
        XCTAssertEqual(HorizontalPartUseGroup.componentIDs(in: groups), ["c-r1", "c-r2", "c-r3", "c-r4"])
        XCTAssertTrue(HorizontalPartUseGroup.groups(usingPart: "p-unused", components: components, blocks: blocks).isEmpty)
    }

    func testTheSubmenuClosesWithAlternatePartsWhichStandsAloneWhereNothingCanBeReplaced() throws {
        let content = HorizontalPartReplaceMenu.content(for: try XCTUnwrap(offer(["c-r1"])))
        guard case .submenu(let title, let entries)? = HorizontalPartReplaceMenu.entry(content, browses: true) else {
            return XCTFail("a submenu")
        }
        XCTAssertEqual(title, "Replace")
        XCTAssertEqual(entries.count, 5)
        guard case .separator = entries[3], case .command("Alternate Parts…", .showAlternateParts) = entries[4] else {
            return XCTFail("a separator, then Alternate Parts…")
        }
        guard case .submenu(_, let plain)? = HorizontalPartReplaceMenu.entry(content, browses: false) else {
            return XCTFail("a submenu")
        }
        XCTAssertEqual(plain.count, 3, "no Pools pane to show them in")
        guard case .command("Alternate Parts…", .showAlternateParts)? = HorizontalPartReplaceMenu.entry(nil, browses: true) else {
            return XCTFail("Alternate Parts… alone")
        }
        XCTAssertNil(HorizontalPartReplaceMenu.entry(nil, browses: false))
        // Before the pools are read, the submenu says so.
        guard case .unavailable("Reading the Pools…", _)? = HorizontalPartReplaceMenu.loading.entries.first else {
            return XCTFail("a dimmed item")
        }
    }
}
