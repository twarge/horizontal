import XCTest
@testable import HorizontalNative

/// A datasheet link reads as its site, "murata.com/…", so it fits on one
/// line; it opens the whole address.
final class HorizontalDatasheetLinkTests: XCTestCase {
    private func short(_ value: String) -> String? {
        HorizontalDatasheetLink.url(value).map(HorizontalDatasheetLink.shortText)
    }

    func testALongAddressReadsAsItsSite() {
        XCTAssertEqual(short("https://www.murata.com/en-us/api/pdfdownloadapi?cate=luCeramicCapacitorsSMD&partno=GRM155R71C104KA88%23"), "murata.com/…")
        XCTAssertEqual(short("https://product.tdk.com/system/files/dam/doc/product/emc/emc/beads/catalog/beads_commercial_signal_mmz1005_en.pdf"),
                       "product.tdk.com/…", "only www. goes")
        XCTAssertEqual(short("http://www.ti.com/?q=opa328"), "ti.com/…", "a query goes further too")
    }

    func testAFrontPageReadsWithoutAnEllipsis() {
        XCTAssertEqual(short("https://www.yageo.com"), "yageo.com")
        XCTAssertEqual(short("https://www.yageo.com/"), "yageo.com")
    }

    func testABareAddressIsTakenAsHTTPS() {
        let url = HorizontalDatasheetLink.url(" www.ti.com/lit/ds/symlink/opa328.pdf ")
        XCTAssertEqual(url?.absoluteString, "https://www.ti.com/lit/ds/symlink/opa328.pdf")
        XCTAssertEqual(short("www.ti.com/lit/ds/symlink/opa328.pdf"), "ti.com/…")
        XCTAssertNil(HorizontalDatasheetLink.url("see the binder"))
    }
}
