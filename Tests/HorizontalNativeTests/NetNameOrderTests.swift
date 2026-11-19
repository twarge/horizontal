import Foundation
import XCTest
@testable import HorizontalNative

/// The order net names are listed in: Finder's, but with `+` just before
/// `-`, so a positive rail or the positive half of a pair is listed first.
final class NetNameOrderTests: XCTestCase {
    private func sorted(_ names: [String]) -> [String] {
        names.shuffled().sorted(by: HorizontalNetNameOrder.precedes)
    }

    func testPositiveRailsAreListedBeforeNegativeOnes() {
        XCTAssertEqual(sorted(["-12V", "-5V", "+12V", "+5V", "+3V3", "GND"]),
                       ["+3V3", "+5V", "+12V", "-5V", "-12V", "GND"],
                       "+ before -, and each sign's rails still by their number")
    }

    func testThePositiveHalfOfAPairIsListedFirst() {
        XCTAssertEqual(sorted(["USB_D-", "USB_DET", "USB_D+", "USB_D"]), ["USB_D", "USB_D+", "USB_D-", "USB_DET"])
        XCTAssertEqual(sorted(["TX10-", "TX2-", "TX10+", "TX2+", "TX1-", "TX1+"]),
                       ["TX1+", "TX1-", "TX2+", "TX2-", "TX10+", "TX10-"],
                       "each pair stays together, the pairs in number order")
        XCTAssertEqual(sorted(["IN-_FILT", "IN+_FILT", "IN-", "IN+"]), ["IN+", "IN+_FILT", "IN-", "IN-_FILT"],
                       "a sign inside the name counts where it stands")
    }

    func testNothingElseComesBetweenTheTwoSigns() {
        // Finder has `/` and `.` between `-` and `+`.
        XCTAssertEqual(sorted(["/CS", "-5V", ".REF", "+5V"]), ["+5V", "-5V", ".REF", "/CS"])
        XCTAssertEqual(sorted(["A.B", "A-B", "A_B", "A+B", "AB"]), ["A_B", "A+B", "A-B", "A.B", "AB"])
    }

    func testNamesWithoutAPlusKeepFindersOrder() {
        let names = ["GND", "gnd", "D10", "D2", "D1", "~RESET", "/CS", "N$12", "N$2", "A-B", "A.B", "A_B", "AB", "a-",
                     "A-", "-5V", "-12V", "VCC_IO", "VCC", "Vcc", "SPI MOSI", "SPI_MOSI", "SPI-MOSI", ""]
        XCTAssertEqual(sorted(names), names.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                       "only + moved")
    }

    func testEveryPairOfNamesIsOrderedOneWayAndTheOrderIsOneOrder() {
        let names = ["+5V", "-5V", "+12V", "-12V", "USB_D+", "USB_D-", "USB_D", "A+B", "A-B", "A\u{2010}B", "A.B", "A_B",
                     "a+", "A+", "a-", "A-", "+", "-", "", "/CS", "~RESET", "VIN+", "Vin-", "TX1+", "TX10-", "TX2+"]
        for a in names {
            XCTAssertEqual(HorizontalNetNameOrder.compare(a, a), .orderedSame)
            for b in names where a != b {
                let order = HorizontalNetNameOrder.compare(a, b)
                XCTAssertNotEqual(order, .orderedSame, "\(a) and \(b) are two names")
                XCTAssertEqual(HorizontalNetNameOrder.compare(b, a), order == .orderedAscending ? .orderedDescending : .orderedAscending,
                               "\(a) against \(b), then the other way round")
                for c in names where order == .orderedAscending && HorizontalNetNameOrder.precedes(b, c) {
                    XCTAssertTrue(HorizontalNetNameOrder.precedes(a, c), "\(a) < \(b) < \(c)")
                }
            }
        }
    }

    func testTheSelectNetSheetListsPlusBeforeMinus() {
        let names = ["-5V", "+5V", "USB_D-", "USB_D+", "GND", "D10", "D2", "  "]
        let nets = names.enumerated().reduce(into: [String: HorizontalNetDetails]()) { nets, item in
            let id = String(format: "aaaaaaaa-0000-4000-8000-%012d", item.offset)
            nets[id] = HorizontalNetDetails(id: id, name: item.element)
        }
        let options = HorizontalNetPickerSheet.options(for: nets)
        XCTAssertEqual(options.map(\.title), ["+5V", "-5V", "aaaaaaaa", "D2", "D10", "GND", "USB_D+", "USB_D-"],
                       "the unnamed net under the start of its id")
        XCTAssertEqual(options.first?.id, "aaaaaaaa-0000-4000-8000-000000000001", "each choice is its net's id")
    }

    func testAPairsPartnerChoicesListPlusBeforeMinus() {
        let plus = "11111111-1111-4111-8111-111111111111", minus = "22222222-2222-4222-8222-222222222222"
        let other = "33333333-3333-4333-8333-333333333333"
        let details = [plus: HorizontalNetDetails(id: plus, name: "D+"), minus: HorizontalNetDetails(id: minus, name: "D-"),
                       other: HorizontalNetDetails(id: other, name: "CLK")]
        XCTAssertEqual(details.values.sorted(by: HorizontalDiffpairProperty.nameOrder).map(\.name), ["CLK", "D+", "D-"])
    }
}
