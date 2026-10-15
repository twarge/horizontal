import Foundation
import XCTest
@testable import HorizontalNative

/// The Pools pane's parametric section (127), Horizon's parametric search
/// (`PoolBrowserParametric`): a table's parts, the values left in each
/// column to filter by, in Horizon's order and format, the filters as its
/// filter boxes apply them, and the list's sort.
final class HorizontalPoolParametricSearchTests: XCTestCase {
    /// horizon-pool's resistors and capacitors, as its tables.json has them.
    private func tables() throws -> [String: HorizontalParametricTable] {
        let json = try JSONHelper.loadDictionary(from: Data("""
        {"tables": {
          "resistors": {"display_name": "Resistors", "columns": [
            {"name": "value", "display_name": "Value", "type": "quantity", "unit": "Ω", "use_si": true, "digits": 2},
            {"name": "tolerance", "display_name": "Tolerance", "type": "quantity", "unit": "%", "use_si": false},
            {"name": "pmax", "display_name": "Power rating", "type": "quantity", "unit": "W", "use_si": false, "digits": 3}]},
          "capacitors": {"display_name": "Capacitors", "columns": [
            {"name": "value", "display_name": "Value", "type": "quantity", "unit": "F", "use_si": true, "digits": 2},
            {"name": "wvdc", "display_name": "Voltage rating", "type": "quantity", "unit": "V", "use_si": false},
            {"name": "type", "display_name": "Type", "type": "enum", "items": ["C0G/NP0", "X5R", "X7R"]}]}
        }}
        """.utf8))
        return Dictionary(uniqueKeysWithValues: json.dictionaryMap("tables").compactMap { name, table in
            HorizontalParametricTable(name: name, json: table).map { (name, $0) }
        })
    }

    private func part(_ name: String, manufacturer: String = "Yageo", package: String = "pkg-0603",
                      entity: String = "e-res", _ parametric: [String: String]) -> HorizontalPoolLibraryItem {
        HorizontalPoolLibraryItem(
            id: "/pool|part|\(name)", uuid: name.lowercased(), name: name, detail: manufacturer, tags: "", category: .part,
            poolName: "Pool", poolURL: URL(fileURLWithPath: "/pool"), url: URL(fileURLWithPath: "/pool/parts/\(name).json"),
            manufacturer: manufacturer, parametric: parametric, packageID: package, partEntityID: entity
        )
    }

    private let packageNames = ["pkg-0603": "R0603", "pkg-0402": "R0402", "pkg-c0603": "C0603"]

    private func resistors() -> [HorizontalPoolLibraryItem] {
        [
            part("R-10K", ["table": "resistors", "value": "10000", "tolerance": "1", "pmax": "0.1"]),
            part("R-4K7", ["table": "resistors", "value": "4.7e3", "tolerance": "1", "pmax": "0.1"]),
            part("R-4K7-0402", package: "pkg-0402", ["table": "resistors", "value": "4700", "tolerance": "5", "pmax": "0.0625"]),
            part("R-100R", manufacturer: "Vishay", ["table": "resistors", "value": "100", "tolerance": "1"]),
            // Not wholly a number: the pool update leaves the part out.
            part("R-BAD", ["table": "resistors", "value": "4.7k", "tolerance": "1"]),
            part("C-100N", package: "pkg-c0603", entity: "e-cap", ["table": "capacitors", "value": "1e-7", "type": "X7R"]),
            part("NO-TABLE", [:]),
        ]
    }

    func testATableHoldsItsPartsWhoseValuesFitItsColumns() throws {
        let tables = try tables()
        let resistors = try XCTUnwrap(tables["resistors"])
        let rows = HorizontalPoolParametricSearch.rows(self.resistors(), table: resistors) { self.packageNames[$0] ?? "" }
        XCTAssertEqual(rows.map(\.item.name), ["R-10K", "R-4K7", "R-4K7-0402", "R-100R"])
        // 4.7e3 and 4700 are one number, as in Horizon's database.
        XCTAssertEqual(rows[1].values["value"], rows[2].values["value"])
        XCTAssertEqual(rows[3].values["pmax"], "", "a value the part doesn't give")
        XCTAssertEqual(rows[2].value(HorizontalParametricFilterColumn.packageName), "R0402")
        XCTAssertEqual(rows[3].value(HorizontalParametricFilterColumn.manufacturerName), "Vishay")

        let capacitors = try XCTUnwrap(tables["capacitors"])
        XCTAssertEqual(HorizontalPoolParametricSearch.rows(self.resistors(), table: capacitors) { _ in "" }.map(\.item.name), ["C-100N"])
        var outOfEnum = self.resistors()[5]
        outOfEnum.parametric["type"] = "Y5V"
        XCTAssertTrue(HorizontalPoolParametricSearch.rows([outOfEnum], table: capacitors) { _ in "" }.isEmpty,
                      "an enum value the column doesn't list leaves the part out")
    }

    func testEachColumnListsTheValuesLeftInHorizonsOrderAndFormat() throws {
        let resistors = try XCTUnwrap(try tables()["resistors"])
        let columns = HorizontalPoolParametricSearch.filterColumns(of: resistors)
        XCTAssertEqual(columns.map(\.name), ["_manufacturer", "_package", "value", "tolerance", "pmax"])
        XCTAssertEqual(columns.map(\.displayName), ["Manufacturer", "Package", "Value", "Tolerance", "Power rating"])
        let rows = HorizontalPoolParametricSearch.rows(self.resistors(), table: resistors) { self.packageNames[$0] ?? "" }
        let remaining = HorizontalPoolParametricSearch.valuesRemaining(rows, columns: columns)
        let value = columns[2], pmax = columns[4]
        // By number, not as text: 100 before 4700 before 10000.
        XCTAssertEqual(remaining["value"]?.map(value.format), ["100.00 Ω", "4.70 kΩ", "10.00 kΩ"])
        // No value first, shown as Horizon shows it.
        XCTAssertEqual(remaining["pmax"]?.map(pmax.format), ["N/A", "0.0625 W", "0.1 W"])
        XCTAssertEqual(remaining["_manufacturer"], ["Vishay", "Yageo"])
        XCTAssertEqual(remaining["_package"], ["R0402", "R0603"])
        XCTAssertEqual(HorizontalParametricFilterColumn.manufacturer.format(""), "N/A")
    }

    /// A box's chosen values wait for Search (or a double-click), replace
    /// that column's filter, and leave every box cleared; the values left
    /// narrow with the list, and a filter can be taken off on its own.
    func testFiltersApplyAsHorizonsFilterBoxesDo() throws {
        let resistors = try XCTUnwrap(try tables()["resistors"])
        let columns = HorizontalPoolParametricSearch.filterColumns(of: resistors)
        let all = HorizontalPoolParametricSearch.rows(self.resistors(), table: resistors) { self.packageNames[$0] ?? "" }
        let fourK7 = try XCTUnwrap(all.first { $0.item.name == "R-4K7" }?.values["value"])
        var filters = HorizontalParametricFilters()
        filters.pending["value"] = [fourK7]
        XCTAssertEqual(HorizontalPoolParametricSearch.filter(all, by: filters.applied).count, 4, "nothing applies until Search")
        filters.apply()
        XCTAssertTrue(filters.pending.isEmpty)
        var rows = HorizontalPoolParametricSearch.filter(all, by: filters.applied)
        XCTAssertEqual(rows.map(\.item.name), ["R-4K7", "R-4K7-0402"])
        XCTAssertEqual(HorizontalPoolParametricSearch.valuesRemaining(rows, columns: columns)["value"]?.count, 1,
                       "one value left, so its box goes away")

        filters.pending["_package"] = ["R0402"]
        filters.apply()
        rows = HorizontalPoolParametricSearch.filter(all, by: filters.applied)
        XCTAssertEqual(rows.map(\.item.name), ["R-4K7-0402"])
        filters.remove("value")
        XCTAssertEqual(HorizontalPoolParametricSearch.filter(all, by: filters.applied).map(\.item.name), ["R-4K7-0402"])
        filters.pending["_package"] = ["R0603"]
        filters.apply()
        XCTAssertEqual(HorizontalPoolParametricSearch.filter(all, by: filters.applied).map(\.item.name), ["R-10K", "R-4K7", "R-100R"],
                       "a column's new values replace its filter")
        filters.reset()
        XCTAssertEqual(filters, HorizontalParametricFilters())
    }

    /// The search and the replacement filter come first, as Horizon's
    /// parametric search keeps to the entity it was given.
    func testTheTableShowsOnlyWhatTheSearchAndTheReplacementLeave() throws {
        let resistors = try XCTUnwrap(try tables()["resistors"])
        let block: JSONDictionary = ["components": ["c-r1": ["refdes": "R1", "entity": "e-res"] as JSONDictionary] as JSONDictionary]
        let replacement = try XCTUnwrap(HorizontalPartReplacement(componentIDs: ["c-r1"], block: block))
        let listed = HorizontalPoolBrowserView.listed(self.resistors(), category: .part, search: "4k7", replacement: replacement)
        let rows = HorizontalPoolParametricSearch.rows(listed, table: resistors) { self.packageNames[$0] ?? "" }
        XCTAssertEqual(rows.map(\.item.name), ["R-4K7", "R-4K7-0402"])
    }

    /// The list sorts by number in a quantity column, a part without one
    /// last, as its database orders it; text sorts naturally.
    func testTheListSortsAQuantityByNumberAndPartsWithoutOneLast() throws {
        let resistors = try XCTUnwrap(try tables()["resistors"])
        let rows = HorizontalPoolParametricSearch.rows(self.resistors(), table: resistors) { self.packageNames[$0] ?? "" }
        func sorted(_ key: String, quantity: Bool, _ order: SortOrder = .forward) -> [String] {
            rows.sorted(using: HorizontalParametricRowComparator(key: key, isQuantity: quantity, order: order)).map(\.item.name)
        }
        XCTAssertEqual(sorted("value", quantity: true), ["R-100R", "R-4K7", "R-4K7-0402", "R-10K"])
        XCTAssertEqual(sorted("value", quantity: true, .reverse), ["R-10K", "R-4K7-0402", "R-4K7", "R-100R"])
        XCTAssertEqual(sorted("pmax", quantity: true), ["R-4K7-0402", "R-4K7", "R-10K", "R-100R"], "ties in MPN order")
        XCTAssertEqual(sorted(HorizontalParametricRowComparator.mpn, quantity: false), ["R-4K7", "R-4K7-0402", "R-10K", "R-100R"])
        XCTAssertEqual(sorted(HorizontalParametricFilterColumn.packageName, quantity: false).first, "R-4K7-0402")
    }

    func testAStoredQuantityIsWhollyANumber() {
        XCTAssertEqual(HorizontalPoolParametricSearch.storedNumber("4700"), 4700)
        XCTAssertEqual(HorizontalPoolParametricSearch.storedNumber(" 4.7e3"), 4700)
        XCTAssertEqual(HorizontalPoolParametricSearch.storedNumber("1e-7"), 1e-7)
        XCTAssertNil(HorizontalPoolParametricSearch.storedNumber("4.7k"))
        XCTAssertNil(HorizontalPoolParametricSearch.storedNumber("4700 "))
        XCTAssertNil(HorizontalPoolParametricSearch.storedNumber(""))
    }
}
