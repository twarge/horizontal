import Foundation
import XCTest
@testable import HorizontalNative

/// The Parts pane's Mouser Stock column: Mouser's Search API as the client
/// asks it, with the user's own key, against a stub server, and the monitor
/// that asks only about the rows on screen and keeps nothing past half an
/// hour in memory, as Mouser's API terms require.
final class HorizontalMouserClientTests: XCTestCase {
    func testABatchIsOneExactSearchWithTheKeyInTheQuery() async throws {
        let server = MouserStubServer { _, _ in .json(MouserFixtures.search) }
        let client = server.client(apiKey: "key-1234")
        let opAmp = HorizontalPartQuery(mpn: "lm358dr", manufacturer: "Texas Instruments")
        let resistor = HorizontalPartQuery(mpn: "RC0402FR-0710KL", manufacturer: "Yageo")
        let missing = HorizontalPartQuery(mpn: "NOT-A-PART", manufacturer: "Nobody")

        let answers = try await client.answers(for: [opAmp, resistor, missing, opAmp])

        let request = try XCTUnwrap(server.requests.only)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.request.url?.path, "/api/v1/search/partnumber")
        XCTAssertEqual(request.request.url?.query, "apiKey=key-1234")
        let body = try XCTUnwrap(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: [String: String]] })
        XCTAssertEqual(body["SearchByPartRequest"]?["partSearchOptions"], "Exact")
        XCTAssertEqual(body["SearchByPartRequest"]?["mouserPartNumber"].map { Set($0.split(separator: "|").map(String.init)) },
                       ["lm358dr", "RC0402FR-0710KL", "NOT-A-PART"], "each MPN once, separated by |")

        guard case .stocked(let ti)? = answers[opAmp.key] else { return XCTFail("TI's LM358DR is stocked") }
        XCTAssertEqual(ti.mouserPartNumber, "595-LM358DR")
        XCTAssertEqual(ti.inStock, 38268, "a count sent as a string")
        XCTAssertEqual(ti.factoryStock, 0)
        XCTAssertEqual(ti.onOrder, [.init(quantity: 2500, date: "2026-11-04T00:00:00")])
        XCTAssertEqual(ti.leadTime, "6 Weeks")
        XCTAssertEqual(ti.productURL?.absoluteString, "https://www.mouser.com/ProductDetail/Texas-Instruments/LM358DR?qs=abc")
        XCTAssertFalse(ti.matchedByMPNOnly)
        XCTAssertFalse(ti.isWindingDown)

        guard case .stocked(let yageo)? = answers[resistor.key] else { return XCTFail("the resistor is stocked") }
        XCTAssertEqual(yageo.inStock, 1234567, "from Availability where AvailabilityInStock is missing")
        XCTAssertTrue(yageo.isWindingDown, "End of Life")
        XCTAssertEqual(answers[missing.key], .notCarried)
    }

    func testAPartIsMatchedByMPNThenMaker() throws {
        let parts = try JSONDecoder().decode(SearchFixture.self, from: MouserFixtures.search).SearchResults.Parts

        guard case .stocked(let st) = HorizontalMouserClient.answer(for: parts, mpn: "LM358DR", manufacturer: "ST Microelectronics") else {
            return XCTFail("ST's LM358DR is stocked")
        }
        XCTAssertEqual(st.mouserPartNumber, "511-LM358DR")
        XCTAssertEqual(st.inStock, 0)
        XCTAssertTrue(st.isDiscontinued)
        XCTAssertTrue(st.isWindingDown)
        XCTAssertEqual(st.suggestedReplacement, "LM358DT")

        guard case .stocked(let unknown) = HorizontalMouserClient.answer(for: parts, mpn: "LM358DR", manufacturer: "Onsemi") else {
            return XCTFail("an MPN Mouser has from other makers still answers")
        }
        XCTAssertEqual(unknown.mouserPartNumber, "595-LM358DR", "the most stocked of them")
        XCTAssertTrue(unknown.matchedByMPNOnly)

        XCTAssertEqual(HorizontalMouserClient.answer(for: parts, mpn: "TPS7A0233PDBVR", manufacturer: "Texas Instruments"), .notCarried,
                       "a listing with no Mouser part number is one Mouser doesn't sell")
        XCTAssertEqual(HorizontalMouserClient.answer(for: parts, mpn: "LM358", manufacturer: "Texas Instruments"), .notCarried,
                       "an MPN that is only the start of others answers nothing")
    }

    func testAKeyMouserRefusesAndACallLimitAreTheirOwnFailures() async throws {
        let refused = MouserStubServer { _, _ in
            .json(#"{"Errors":[{"Id":0,"Code":"Invalid","Message":"Invalid unique identifier.","ResourceKey":"InvalidIdentifier","ResourceFormatString":null,"ResourceFormatString2":null,"PropertyName":"API Key"}],"SearchResults":null}"#)
        }
        do {
            _ = try await refused.client().answers(for: [HorizontalPartQuery(mpn: "LM358DR", manufacturer: "")])
            XCTFail("refused")
        } catch let failure as HorizontalMouserClient.Failure {
            XCTAssertEqual(failure, .unauthorized("Mouser didn't accept the API key (Invalid unique identifier.)."))
        }

        let perMinute = MouserStubServer { _, _ in
            .status(403, #"{"Errors":[{"Id":0,"Code":"TooManyRequests","Message":"Maximum calls per minute exceeded.","ResourceKey":"TooManyRequests","PropertyName":null}],"SearchResults":null}"#)
        }
        do {
            _ = try await perMinute.client().answers(for: [HorizontalPartQuery(mpn: "LM358DR", manufacturer: "")])
            XCTFail("limited")
        } catch let failure as HorizontalMouserClient.Failure {
            XCTAssertEqual(failure, .rateLimited(retryAfter: 60, message: "Maximum calls per minute exceeded."),
                           "a limit, though it came with a 403")
        }

        let perDay = MouserStubServer { _, _ in
            .json(#"{"Errors":[{"Code":"TooManyRequests","Message":"Maximum calls per day exceeded."}]}"#)
        }
        do {
            _ = try await perDay.client().answers(for: [HorizontalPartQuery(mpn: "LM358DR", manufacturer: "")])
            XCTFail("limited")
        } catch let failure as HorizontalMouserClient.Failure {
            XCTAssertEqual(failure, .rateLimited(retryAfter: HorizontalMouserClient.dailyLimitBackoff, message: "Maximum calls per day exceeded."))
            XCTAssertEqual(failure.message, "Mouser's call limit was reached (Maximum calls per day exceeded.). Try again in 1 hour.")
        }

        let throttled = MouserStubServer { _, _ in .status(429, "", headers: ["Retry-After": "30"]) }
        do {
            _ = try await throttled.client().answers(for: [HorizontalPartQuery(mpn: "LM358DR", manufacturer: "")])
            XCTFail("limited")
        } catch let failure as HorizontalMouserClient.Failure {
            XCTAssertEqual(failure, .rateLimited(retryAfter: 30, message: ""))
        }

        let other = MouserStubServer { _, _ in
            .json(#"{"Errors":[{"Code":"Required","Message":"Part Number is required.","PropertyName":"mouserPartNumber"}]}"#)
        }
        do {
            _ = try await other.client().answers(for: [HorizontalPartQuery(mpn: "LM358DR", manufacturer: "")])
            XCTFail("refused")
        } catch let failure as HorizontalMouserClient.Failure {
            XCTAssertEqual(failure, .refused("Mouser refused the search: Part Number is required."))
        }
    }

    /// Mouser sends at most 50 parts for a search; a batch it cut short asks
    /// again about the parts it found nothing for, one by one.
    func testACutShortBatchAsksAgainAboutWhatItMissed() async throws {
        let server = MouserStubServer { request, _ in
            let body = request.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: String]] }
            let mpns = body?["SearchByPartRequest"]?["mouserPartNumber"] ?? ""
            return mpns.contains("|")
                ? .json(#"{"Errors":[],"SearchResults":{"NumberOfResult":120,"Parts":[\#(MouserFixtures.tiOpAmp)]}}"#)
                : .json(#"{"Errors":[],"SearchResults":{"NumberOfResult":1,"Parts":[\#(MouserFixtures.yageoResistor)]}}"#)
        }
        let opAmp = HorizontalPartQuery(mpn: "LM358DR", manufacturer: "Texas Instruments")
        let resistor = HorizontalPartQuery(mpn: "RC0402FR-0710KL", manufacturer: "Yageo")
        let answers = try await server.client().answers(for: [opAmp, resistor])
        XCTAssertEqual(server.requests.count, 2)
        guard case .stocked? = answers[opAmp.key], case .stocked? = answers[resistor.key] else {
            return XCTFail("both found: \(answers)")
        }
    }

    func testAnMPNTheSearchCannotCarryIsNeverSent() async throws {
        XCTAssertTrue(HorizontalMouserClient.canSearch("LM358DR"))
        XCTAssertFalse(HorizontalMouserClient.canSearch("R1"), "shorter than 3")
        XCTAssertFalse(HorizontalMouserClient.canSearch(String(repeating: "A", count: 41)), "longer than 40")
        XCTAssertFalse(HorizontalMouserClient.canSearch("AB|CD"), "the batch separator")
        let server = MouserStubServer { _, _ in .json(MouserFixtures.search) }
        do {
            _ = try await server.client().answers(for: [HorizontalPartQuery(mpn: "R1", manufacturer: "")])
            XCTFail("unsearchable")
        } catch let failure as HorizontalMouserClient.Failure {
            XCTAssertEqual(failure, .unsearchable("Mouser's part number search takes part numbers of 3 to 40 characters."))
        }
        XCTAssertTrue(server.requests.isEmpty)
    }
}

@MainActor
final class HorizontalMouserStockMonitorTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "horizontal-mouser-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func waitUntilIdle(_ monitor: HorizontalMouserStockMonitor, _ server: MouserStubServer, requests: Int) async throws {
        for _ in 0..<500 where server.requests.count < requests || !monitor.checking.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.requests.count, requests)
        XCTAssertTrue(monitor.checking.isEmpty, "the lookups finished")
    }

    /// Lets a gather delay pass with nothing sent.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private func makeMonitor(
        _ server: MouserStubServer,
        defaults: UserDefaults? = nil,
        key: String? = "key",
        clock: Clock = Clock(),
        gather: Duration = .milliseconds(30)
    ) throws -> HorizontalMouserStockMonitor {
        HorizontalMouserStockMonitor(
            defaults: try defaults ?? makeDefaults(),
            secrets: .memory(key),
            gatherDelay: gather,
            now: { clock.now },
            makeClient: { server.client(apiKey: $0) }
        )
    }

    /// The column's rows: what is on screen is asked about in one batch,
    /// once; a row that went before the gather delay is not; an answer is
    /// held for half an hour, in memory only, then asked for again.
    func testOnlyTheRowsOnScreenAreAskedAboutAndAnswersAreNotKept() async throws {
        let server = MouserStubServer { _, _ in .json(MouserFixtures.search) }
        let clock = Clock()
        let monitor = try makeMonitor(server, clock: clock)
        let opAmp = HorizontalPartQuery(mpn: "LM358DR", manufacturer: "Texas Instruments")
        let resistor = HorizontalPartQuery(mpn: "RC0402FR-0710KL", manufacturer: "Yageo")
        let scrolledPast = HorizontalPartQuery(mpn: "NOT-A-PART", manufacturer: "Nobody")

        XCTAssertEqual(monitor.state(for: opAmp), .pending)
        monitor.show(opAmp)
        monitor.show(resistor)
        monitor.show(scrolledPast)
        monitor.hide(scrolledPast)
        try await waitUntilIdle(monitor, server, requests: 1)
        let sent = try XCTUnwrap(server.requests.first?.bodyText)
        XCTAssertTrue(sent.contains("LM358DR|RC0402FR-0710KL") || sent.contains("RC0402FR-0710KL|LM358DR"), sent)
        XCTAssertFalse(sent.contains("NOT-A-PART"), "a row scrolled past is not asked about")
        XCTAssertEqual(monitor.state(for: opAmp).title, 38268.formatted())
        XCTAssertEqual(monitor.state(for: scrolledPast), .pending)

        monitor.hide(opAmp)
        monitor.show(opAmp)
        try await settle()
        XCTAssertEqual(server.requests.count, 1, "a held answer is not asked for again")

        clock.now += HorizontalMouserStockMonitor.holdFor + 1
        XCTAssertNil(monitor.productURL(for: opAmp), "the page goes with the answer's time")
        monitor.hide(opAmp)
        monitor.show(opAmp)
        XCTAssertTrue(monitor.state(for: opAmp).hasAnswer, "the old answer shows while it is asked about again")
        try await waitUntilIdle(monitor, server, requests: 2)
        guard case .answer(_, let checkedAt, false) = monitor.state(for: opAmp) else {
            return XCTFail("answered again: \(monitor.state(for: opAmp))")
        }
        XCTAssertEqual(checkedAt, clock.now)
        XCTAssertNotNil(monitor.records[resistor.key], "a part still shown keeps its old answer")
        monitor.hide(resistor)
        monitor.hide(opAmp)
        monitor.lookUp([scrolledPast])
        try await waitUntilIdle(monitor, server, requests: 3)
        XCTAssertNil(monitor.records[resistor.key], "an old answer no row shows is let go")
        XCTAssertEqual(monitor.state(for: scrolledPast).title, "Not carried", "a menu's check asks whether or not a row shows it")
    }

    func testAMenusCheckAsksAgainAtOnce() async throws {
        let server = MouserStubServer { _, _ in .json(MouserFixtures.search) }
        let monitor = try makeMonitor(server)
        let opAmp = HorizontalPartQuery(mpn: "LM358DR", manufacturer: "Texas Instruments")
        monitor.show(opAmp)
        try await waitUntilIdle(monitor, server, requests: 1)
        monitor.lookUp([opAmp], force: false)
        try await settle()
        XCTAssertEqual(server.requests.count, 1, "unforced, a held answer stands")
        monitor.lookUp([opAmp])
        try await waitUntilIdle(monitor, server, requests: 2)
    }

    /// Settings' switch and the key: off, nothing is asked and what was held
    /// is forgotten, and it stays off at the next launch; a new key starts
    /// over with the rows on screen; no key, nothing is asked.
    func testTheSwitchAndTheKeyForgetWhatWasHeld() async throws {
        let server = MouserStubServer { _, _ in .json(MouserFixtures.search) }
        let defaults = try makeDefaults()
        let monitor = try makeMonitor(server, defaults: defaults, key: nil)
        let opAmp = HorizontalPartQuery(mpn: "LM358DR", manufacturer: "Texas Instruments")
        XCTAssertTrue(monitor.isEnabled, "on until turned off")
        XCTAssertEqual(monitor.state(for: opAmp), .notSetUp)

        monitor.show(opAmp)
        try await settle()
        XCTAssertTrue(server.requests.isEmpty, "nothing is asked without a key")

        try monitor.saveAPIKey(" key ")
        try await waitUntilIdle(monitor, server, requests: 1)
        XCTAssertEqual(server.requests.first?.request.url?.query, "apiKey=key", "a new key asks about the rows on screen")
        XCTAssertNotNil(monitor.productURL(for: opAmp))

        monitor.isEnabled = false
        XCTAssertEqual(monitor.state(for: opAmp), .off)
        XCTAssertTrue(monitor.records.isEmpty, "turning it off forgets the answers")
        monitor.lookUp([opAmp])
        await monitor.verifyAPIKey()
        XCTAssertEqual(server.requests.count, 1, "no request of any kind while off")
        XCTAssertNil(monitor.verification)
        XCTAssertFalse(try makeMonitor(server, defaults: defaults).isEnabled, "kept between launches")

        monitor.isEnabled = true
        try await waitUntilIdle(monitor, server, requests: 2)
        try monitor.removeAPIKey()
        XCTAssertTrue(monitor.records.isEmpty, "removing the key forgets the answers")
        XCTAssertEqual(monitor.state(for: opAmp), .notSetUp)
    }

    func testARefusedKeyStopsTheLookupsUntilTheKeyChanges() async throws {
        let server = MouserStubServer { request, _ in
            request.url?.query == "apiKey=bad"
                ? .json(#"{"Errors":[{"Code":"Invalid","Message":"Invalid unique identifier.","PropertyName":"API Key"}]}"#)
                : .json(MouserFixtures.search)
        }
        let monitor = try makeMonitor(server, key: "bad")
        let opAmp = HorizontalPartQuery(mpn: "LM358DR", manufacturer: "Texas Instruments")
        let resistor = HorizontalPartQuery(mpn: "RC0402FR-0710KL", manufacturer: "Yageo")
        monitor.show(opAmp)
        try await waitUntilIdle(monitor, server, requests: 1)
        let message = "Mouser didn't accept the API key (Invalid unique identifier.)."
        XCTAssertEqual(monitor.problem, message)
        XCTAssertEqual(monitor.verification, .refused(message))
        XCTAssertEqual(monitor.state(for: opAmp), .unavailable(message))

        monitor.show(resistor)
        monitor.lookUp([opAmp])
        try await settle()
        XCTAssertEqual(server.requests.count, 1, "stopped")

        try monitor.saveAPIKey("good")
        XCTAssertNil(monitor.problem)
        try await waitUntilIdle(monitor, server, requests: 2)
        XCTAssertEqual(monitor.state(for: resistor).title, 1234567.formatted(), "a new key starts over")
    }

    /// A part the search can't carry fails at once, asking nothing.
    func testAnUnsearchableMPNFailsWithoutARequest() async throws {
        let server = MouserStubServer { _, _ in .json(MouserFixtures.search) }
        let monitor = try makeMonitor(server)
        let short = HorizontalPartQuery(mpn: "R1", manufacturer: "")
        monitor.show(short)
        // Until the row has stayed up for the gather delay the cell reads
        // pending, and a busy CI runner can take longer than a fixed sleep.
        for _ in 0..<500 where monitor.state(for: short) == .pending {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(monitor.state(for: short), .failed("Mouser's part number search takes part numbers of 3 to 40 characters."))
    }

    /// A part's Open on Mouser, on the canvases and in the panes: Mouser's
    /// search for its MPN, needing no key, unless an answer is held, whose
    /// page it opens; none while Mouser is off. DigiKey's comes first.
    func testAPartsMouserLinkIsItsSearchUnlessAnAnswerIsHeld() async throws {
        let server = MouserStubServer { _, _ in .json(MouserFixtures.search) }
        let monitor = try makeMonitor(server, key: nil)
        let digiKey = HorizontalDigiKeyStockMonitor(defaults: try makeDefaults(), secrets: .memory(), cacheURL: nil)
        func links(_ mpn: String, _ manufacturer: String = "Texas Instruments") -> [HorizontalPartPageLink] {
            HorizontalPartPageLink.links(mpn: mpn, manufacturer: manufacturer, digiKey: digiKey, mouser: monitor)
        }

        XCTAssertEqual(links(" LM358DR ").map(\.title), ["Open on DigiKey", "Open on Mouser"])
        XCTAssertEqual(links("LM358DR").last?.url.absoluteString, "https://www.mouser.com/c/?q=LM358DR")
        XCTAssertEqual(links("AB+C#1/2&x=y").last?.url.absoluteString, "https://www.mouser.com/c/?q=AB%2BC%231/2%26x%3Dy",
                       "an MPN reaches the search as itself")
        XCTAssertEqual(links(" "), [], "no MPN, no link")
        XCTAssertTrue(server.requests.isEmpty, "a link asks Mouser nothing")

        try monitor.saveAPIKey("key")
        monitor.lookUp([HorizontalPartQuery(mpn: "LM358DR", manufacturer: "Texas Instruments")])
        try await waitUntilIdle(monitor, server, requests: 1)
        XCTAssertEqual(links("LM358DR").last?.url.absoluteString, "https://www.mouser.com/ProductDetail/Texas-Instruments/LM358DR?qs=abc")

        monitor.isEnabled = false
        XCTAssertEqual(links("LM358DR").map(\.title), ["Open on DigiKey"], "none while Mouser is off")
    }

    /// The cell's tooltip credits Mouser, and says what is on order.
    func testTheCellCreditsMouser() throws {
        let parts = try JSONDecoder().decode(SearchFixture.self, from: MouserFixtures.search).SearchResults.Parts
        let answer = HorizontalMouserClient.answer(for: parts, mpn: "LM358DR", manufacturer: "ST Microelectronics")
        let cell = HorizontalMouserStockMonitor.CellState.answer(answer, checkedAt: Date(), isRefreshing: false)
        XCTAssertEqual(cell.title, "0")
        XCTAssertTrue(cell.isWarning)
        let help = cell.help(for: MouserFixtures.part(mpn: "LM358DR", manufacturer: "ST Microelectronics"))
        XCTAssertTrue(help.contains("STMicroelectronics LM358DR at Mouser (511-LM358DR)"), help)
        XCTAssertTrue(help.contains("Discontinued at Mouser"), help)
        XCTAssertTrue(help.contains("Suggested replacement: LM358DT"), help)
        XCTAssertTrue(help.contains("Lead time: 52 Weeks"), help)
        XCTAssertTrue(help.contains("Stock data from Mouser Electronics."), help)

        let ti = HorizontalMouserClient.answer(for: parts, mpn: "LM358DR", manufacturer: "Texas Instruments")
        let tiHelp = HorizontalMouserStockMonitor.CellState.answer(ti, checkedAt: Date(), isRefreshing: false)
            .help(for: MouserFixtures.part(mpn: "LM358DR", manufacturer: "Texas Instruments"))
        XCTAssertTrue(tiHelp.contains("On order: \(2500.formatted()), expected 2026-11-04"), tiHelp)
        XCTAssertFalse(tiHelp.contains("Lead time"), "there is stock")
        XCTAssertTrue(tiHelp.contains("Click to open the part on Mouser."))
    }
}

private struct SearchFixture: Decodable {
    struct Results: Decodable { var Parts: [HorizontalMouserClient.Part] }
    var SearchResults: Results
}

private enum MouserFixtures {
    static let tiOpAmp = #"""
    {
      "Availability": "38268 In Stock",
      "DataSheetUrl": "https://www.mouser.com/datasheet/2/405/lm358.pdf",
      "Description": "Operational Amplifiers - Op Amps Dual Gen Pur Op Amp",
      "FactoryStock": "0",
      "LeadTime": "6 Weeks",
      "LifecycleStatus": null,
      "Manufacturer": "Texas Instruments",
      "ManufacturerPartNumber": "LM358DR",
      "Min": "1",
      "Mult": "1",
      "MouserPartNumber": "595-LM358DR",
      "PriceBreaks": [{"Quantity": 1, "Price": "$0.42", "Currency": "USD"}],
      "ProductDetailUrl": "https://www.mouser.com/ProductDetail/Texas-Instruments/LM358DR?qs=abc",
      "IsDiscontinued": "false",
      "SuggestedReplacement": "",
      "AvailabilityInStock": "38268",
      "AvailabilityOnOrder": [{"Quantity": 2500, "Date": "2026-11-04T00:00:00"}]
    }
    """#

    static let yageoResistor = #"""
    {
      "Availability": "1,234,567 In Stock",
      "FactoryStock": "4000000",
      "LifecycleStatus": "End of Life",
      "Manufacturer": "YAGEO",
      "ManufacturerPartNumber": "RC0402FR-0710KL",
      "MouserPartNumber": "603-RC0402FR-0710KL",
      "ProductDetailUrl": "https://www.mouser.com/ProductDetail/YAGEO/RC0402FR-0710KL?qs=def",
      "IsDiscontinued": "false"
    }
    """#

    static let search = Data(#"""
    {
      "Errors": [],
      "SearchResults": {
        "NumberOfResult": 4,
        "Parts": [
          \#(tiOpAmp),
          {
            "Availability": "None",
            "FactoryStock": "0",
            "LeadTime": "52 Weeks",
            "Manufacturer": "STMicroelectronics",
            "ManufacturerPartNumber": "LM358DR",
            "MouserPartNumber": "511-LM358DR",
            "ProductDetailUrl": "https://www.mouser.com/ProductDetail/STMicroelectronics/LM358DR?qs=ghi",
            "IsDiscontinued": "true",
            "SuggestedReplacement": "LM358DT",
            "AvailabilityInStock": null
          },
          \#(yageoResistor),
          {
            "Availability": "",
            "Manufacturer": "Texas Instruments",
            "ManufacturerPartNumber": "TPS7A0233PDBVR",
            "MouserPartNumber": "N/A"
          }
        ]
      }
    }
    """#.utf8)

    static func part(mpn: String, manufacturer: String) -> HorizontalPoolPart {
        HorizontalPoolPart(
            id: UUID().uuidString.lowercased(),
            mpn: mpn,
            manufacturer: manufacturer,
            partDescription: "",
            packageName: "",
            tags: [],
            value: "",
            displayValue: mpn,
            entityID: nil,
            refdesPrefix: "U",
            gates: []
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private extension URLRequest {
    /// The body as the stub read it, from the stream URLSession turns it into.
    var bodyData: Data? {
        httpBody ?? value(forHTTPHeaderField: MouserStubProtocol.bodyHeader).flatMap { Data(base64Encoded: $0) }
    }
}

/// A Mouser that answers from a closure and records what it was asked:
/// each request with its body, and how many came before it.
private final class MouserStubServer: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]

        static func json(_ text: String) -> Reply { Reply(status: 200, body: Data(text.utf8)) }
        static func json(_ data: Data) -> Reply { Reply(status: 200, body: data) }
        static func status(_ status: Int, _ text: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: headers)
        }
    }

    struct Recorded {
        var request: URLRequest
        var body: Data?
        var bodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private let respond: @Sendable (URLRequest, Int) -> Reply
    let id = UUID().uuidString

    init(_ respond: @escaping @Sendable (URLRequest, Int) -> Reply) {
        self.respond = respond
        MouserStubProtocol.register(self)
    }

    deinit {
        MouserStubProtocol.unregister(id)
    }

    var requests: [Recorded] {
        lock.withLock { recorded }
    }

    func handle(_ request: URLRequest, body: Data?) -> Reply {
        let count = lock.withLock {
            recorded.append(Recorded(request: request, body: body))
            return recorded.count - 1
        }
        var withBody = request
        if let body {
            withBody.setValue(body.base64EncodedString(), forHTTPHeaderField: MouserStubProtocol.bodyHeader)
        }
        return respond(withBody, count)
    }

    func client(apiKey: String = "key") -> HorizontalMouserClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MouserStubProtocol.self]
        configuration.httpAdditionalHeaders = [MouserStubProtocol.serverHeader: id]
        return HorizontalMouserClient(apiKey: apiKey, session: URLSession(configuration: configuration), requestSpacing: .zero)
    }
}

private final class MouserStubProtocol: URLProtocol {
    static let serverHeader = "X-Stub-Server"
    static let bodyHeader = "X-Stub-Body"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: MouserStubServer] = [:]

    static func register(_ server: MouserStubServer) {
        lock.withLock { servers[server.id] = server }
    }

    static func unregister(_ id: String) {
        lock.withLock { servers[id] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.serverHeader) ?? ""
        guard let server = Self.lock.withLock({ Self.servers[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = server.handle(request, body: request.httpBody ?? request.httpBodyStream.map(Self.read))
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
