import Foundation
import XCTest
@testable import HorizontalNative

/// The power net editor keeps the order its rows are dragged into, which
/// Horizon's files have no place for.
final class HorizontalPowerNetOrderTests: XCTestCase {
    private func net(_ id: String, _ name: String) -> HorizontalPowerNetSummary {
        HorizontalPowerNetSummary(id: id, name: name, style: "gnd", isInUse: false)
    }

    func testRankedNetsComeFirstAndTheRestKeepTheirNameOrder() {
        let nets = [net("a", "3V3"), net("b", "5V"), net("c", "GND"), net("d", "VCC")]
        let sorted = HorizontalPowerNetOrder.sorted(nets, id: \.id, ranks: ["d": 0, "c": 1, "other-project": 0])
        XCTAssertEqual(sorted.map(\.name), ["VCC", "GND", "3V3", "5V"],
                       "a net never ranked, such as a new one, goes after the ranked ones")
        XCTAssertEqual(HorizontalPowerNetOrder.sorted(nets, id: \.id, ranks: [:]).map(\.name), ["3V3", "5V", "GND", "VCC"])
    }

    func testARowDraggedOverAnotherTakesItsPlace() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(HorizontalPowerNetOrder.moving("a", to: "c", in: ids), ["b", "c", "a", "d"], "down: after the row it is over")
        XCTAssertEqual(HorizontalPowerNetOrder.moving("d", to: "b", in: ids), ["a", "d", "b", "c"], "up: before it")
        XCTAssertEqual(HorizontalPowerNetOrder.moving("b", to: "b", in: ids), ids)
        XCTAssertEqual(HorizontalPowerNetOrder.moving("x", to: "b", in: ids), ids)
    }

    func testRankingKeepsOtherProjectsNetsAndIgnoresCase() {
        let ranks = HorizontalPowerNetOrder.ranking(["B", "a"], over: ["a": 0, "b": 1, "elsewhere": 3])
        XCTAssertEqual(ranks, ["b": 0, "a": 1, "elsewhere": 3])
        XCTAssertEqual(HorizontalPowerNetOrder.sorted([net("A", "x"), net("B", "y")], id: \.id, ranks: ranks).map(\.id), ["B", "A"])
    }

    func testTheOrderIsKeptInDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HorizontalPowerNetOrderTests"))
        defer { defaults.removePersistentDomain(forName: "HorizontalPowerNetOrderTests") }
        XCTAssertEqual(HorizontalPowerNetOrder.ranks(in: defaults), [:])
        HorizontalPowerNetOrder.save(["a": 1, "b": 0], to: defaults)
        XCTAssertEqual(HorizontalPowerNetOrder.ranks(in: defaults), ["a": 1, "b": 0])
    }
}
