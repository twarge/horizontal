import Foundation
import XCTest
@testable import HorizontalNative

/// The Parts pane's Arrow Stock column: Arrow's Pricing & Availability API
/// as the client asks it, with the user's own login and key, against a stub
/// server answering as Arrow's documentation shows, and the monitor that
/// asks only about the rows on screen and keeps nothing past half an hour
/// in memory.
final class HorizontalArrowClientTests: XCTestCase {
    func testAPartIsOneTokenSearchWithTheLoginAndKeyInTheQuery() async throws {
        let server = ArrowStubServer { _, _ in .json(ArrowFixtures.search) }
        let client = server.client(login: "me@example", apiKey: "key+1234")

        let answer = try await client.answer(for: HorizontalPartQuery(mpn: "bav99", manufacturer: "Nexperia"))

        let request = try XCTUnwrap(server.requests.only)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.arrow.com")
        XCTAssertEqual(request.url?.path, "/itemservice/v4/en/search/token")
        XCTAssertEqual(request.url?.query(percentEncoded: true), "login=me@example&apikey=key%2B1234&search_token=bav99&rows=25",
                       "the key reaches Arrow as itself")

        guard case .stocked(let stock) = answer else { return XCTFail("Nexperia's BAV99 is stocked") }
        XCTAssertEqual(stock.manufacturer, "Nexperia")
        XCTAssertEqual(stock.manufacturerPartNumber, "BAV99")
        XCTAssertEqual(stock.inStock, 21_000, "arrow.com's sources together, a count sent as a string among them")
        XCTAssertEqual(stock.elsewhere, [.init(name: "Verical", quantity: 9000)])
        XCTAssertEqual(stock.productURL?.absoluteString, "https://www.arrow.com/en/products/bav99/nexperia")
        XCTAssertFalse(stock.matchedByMPNOnly)
    }

    /// The token search is a prefix search: BAV99 brings BAV99W with it.
    func testAPartIsMatchedByMPNThenMaker() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ArrowFixtures.search.utf8)) as? [String: Any])
        let parts = try HorizontalArrowClient.parts(in: try XCTUnwrap(root["itemserviceresult"] as? [String: Any]))
        XCTAssertEqual(parts.map(\.manufacturerPartNumber), ["BAV99", "BAV99", "BAV99W"])

        func stock(_ mpn: String, _ maker: String) -> HorizontalArrowStock? {
            if case .stocked(let stock) = HorizontalArrowClient.answer(for: parts, mpn: mpn, manufacturer: maker) { return stock }
            return nil
        }
        XCTAssertEqual(stock("BAV99", "onsemi")?.inStock, 500)
        XCTAssertEqual(stock("BAV99", "onsemi")?.productURL?.absoluteString, "https://www.arrow.com/en/products/bav99/onsemi",
                       "the source's own page where the part has none")
        XCTAssertEqual(stock("bav 99", "Vishay")?.manufacturer, "Nexperia", "no Vishay: the one with the most on hand")
        XCTAssertEqual(stock("BAV99", "Vishay")?.matchedByMPNOnly, true)
        XCTAssertEqual(stock("BAV99W", "Nexperia")?.inStock, 0, "listed, with none on hand")
        XCTAssertEqual(HorizontalArrowClient.answer(for: parts, mpn: "BAV9", manufacturer: "Nexperia"), .notCarried,
                       "a longer part number is another part")
    }

    func testFindingNothingIsAnAnswerAndARefusedKeyIsAFailure() async throws {
        func failure(_ reply: ArrowStubServer.Reply) async -> HorizontalArrowClient.Failure? {
            let server = ArrowStubServer { _, _ in reply }
            do {
                _ = try await server.client().answer(for: HorizontalPartQuery(mpn: "BAV99", manufacturer: ""))
                return nil
            } catch {
                return error as? HorizontalArrowClient.Failure
            }
        }
        @Sendable func refusal(_ message: String) -> ArrowStubServer.Reply {
            .json(#"{"itemserviceresult":{"transactionArea":[{"response":{"returnCode":"1","returnMsg":"\#(message)","success":false}}],"data":[]}}"#)
        }

        let nothing = ArrowStubServer { _, _ in refusal("No Results Found") }
        let answer = try await nothing.client().answer(for: HorizontalPartQuery(mpn: "NOT-A-PART", manufacturer: ""))
        XCTAssertEqual(answer, .notCarried)
        let empty = ArrowStubServer { _, _ in .json(#"{"itemserviceresult":{"data":[]}}"#) }
        let emptyAnswer = try await empty.client().answer(for: HorizontalPartQuery(mpn: "NOT-A-PART", manufacturer: ""))
        XCTAssertEqual(emptyAnswer, .notCarried)

        guard case .unauthorized(let message)? = await failure(refusal("Invalid login or apikey")) else {
            return XCTFail("a refused key")
        }
        XCTAssertTrue(message.contains("Invalid login or apikey"), message)
        guard case .unauthorized? = await failure(.status(403, "Forbidden")) else { return XCTFail("HTTP 403") }
        let limited = await failure(.status(429, "", headers: ["Retry-After": "120"]))
        XCTAssertEqual(limited, .rateLimited(retryAfter: 120))
        let refused = await failure(refusal("search_token is required"))
        XCTAssertEqual(refused, .refused("Arrow refused the search: search_token is required"))
        let malformed = await failure(.json("<html>"))
        XCTAssertEqual(malformed, .malformedResponse)
        let down = await failure(.status(503, "down for maintenance"))
        XCTAssertEqual(down, .http(status: 503, detail: "down for maintenance"))
    }
}

@MainActor
final class HorizontalArrowStockMonitorTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "horizontal-arrow-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func waitUntilIdle(_ monitor: HorizontalArrowStockMonitor, _ server: ArrowStubServer, requests: Int) async throws {
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

    /// A monitor turned on, with a login and key unless `setUp` is false.
    private func makeMonitor(
        _ server: ArrowStubServer,
        defaults: UserDefaults? = nil,
        setUp: Bool = true,
        clock: Clock = Clock()
    ) throws -> HorizontalArrowStockMonitor {
        let defaults = try defaults ?? makeDefaults()
        defaults.set(true, forKey: HorizontalArrowStockMonitor.enabledKey)
        if setUp {
            defaults.set("me@example", forKey: HorizontalArrowStockMonitor.loginKey)
        }
        return HorizontalArrowStockMonitor(
            defaults: defaults,
            secrets: .memory(setUp ? "key" : nil),
            gatherDelay: .milliseconds(30),
            now: { clock.now },
            makeClient: { server.client(login: $0.login, apiKey: $0.apiKey) }
        )
    }

    private let diode = HorizontalPartQuery(mpn: "BAV99", manufacturer: "Nexperia")
    private let other = HorizontalPartQuery(mpn: "BAV99W", manufacturer: "Nexperia")
    private let scrolledPast = HorizontalPartQuery(mpn: "NOT-A-PART", manufacturer: "Nobody")

    func testArrowIsOffUntilTurnedOn() throws {
        let defaults = try makeDefaults()
        let monitor = HorizontalArrowStockMonitor(defaults: defaults, secrets: .memory())
        XCTAssertFalse(monitor.isEnabled, "Arrow issues a login and key only on request")
        XCTAssertEqual(monitor.state(for: diode), .off)
        monitor.isEnabled = true
        XCTAssertEqual(monitor.state(for: diode), .notSetUp)
        XCTAssertTrue(HorizontalArrowStockMonitor(defaults: defaults, secrets: .memory()).isEnabled, "kept between launches")
    }

    /// The column's rows: each part on screen is asked about once, one
    /// request apiece; a row that went before the gather delay is not; an
    /// answer is held for half an hour, in memory only, then asked for again.
    func testOnlyTheRowsOnScreenAreAskedAboutAndAnswersAreNotKept() async throws {
        let server = ArrowStubServer { _, _ in .json(ArrowFixtures.search) }
        let clock = Clock()
        let monitor = try makeMonitor(server, clock: clock)

        XCTAssertEqual(monitor.state(for: diode), .pending)
        monitor.show(diode)
        monitor.show(other)
        monitor.show(scrolledPast)
        monitor.hide(scrolledPast)
        try await waitUntilIdle(monitor, server, requests: 2)
        XCTAssertEqual(Set(server.requests.compactMap { $0.url?.query(percentEncoded: true) }), [
            "login=me@example&apikey=key&search_token=BAV99&rows=25",
            "login=me@example&apikey=key&search_token=BAV99W&rows=25",
        ], "a row scrolled past is not asked about")
        XCTAssertEqual(monitor.state(for: diode).title, 21_000.formatted())
        XCTAssertFalse(monitor.state(for: diode).isWarning)
        XCTAssertEqual(monitor.state(for: other).title, "0")
        XCTAssertTrue(monitor.state(for: other).isWarning, "none on hand")
        XCTAssertEqual(monitor.state(for: scrolledPast), .pending)

        monitor.hide(diode)
        monitor.show(diode)
        try await settle()
        XCTAssertEqual(server.requests.count, 2, "a held answer is not asked for again")

        clock.now += HorizontalArrowStockMonitor.holdFor + 1
        XCTAssertNil(monitor.productURL(for: diode), "the page goes with the answer's time")
        monitor.hide(diode)
        monitor.show(diode)
        XCTAssertTrue(monitor.state(for: diode).hasAnswer, "the old answer shows while it is asked about again")
        try await waitUntilIdle(monitor, server, requests: 3)
        guard case .answer(_, let checkedAt, false) = monitor.state(for: diode) else {
            return XCTFail("answered again: \(monitor.state(for: diode))")
        }
        XCTAssertEqual(checkedAt, clock.now)
        monitor.hide(other)
        monitor.hide(diode)
        monitor.lookUp([scrolledPast])
        try await waitUntilIdle(monitor, server, requests: 4)
        XCTAssertNil(monitor.records[other.key], "an old answer no row shows is let go")
        XCTAssertEqual(monitor.state(for: scrolledPast).title, "Not carried", "a menu's check asks whether or not a row shows it")
    }

    /// Settings' switch and the login and key: off, nothing is asked and
    /// what was held is forgotten; new ones start over with the rows on
    /// screen; without both, nothing is asked.
    func testTheSwitchAndTheCredentialsForgetWhatWasHeld() async throws {
        let server = ArrowStubServer { _, _ in .json(ArrowFixtures.search) }
        let monitor = try makeMonitor(server, setUp: false)
        monitor.show(diode)
        try await settle()
        XCTAssertTrue(server.requests.isEmpty, "not set up, nothing is asked")
        XCTAssertEqual(monitor.state(for: diode), .notSetUp)

        try monitor.saveCredentials(login: " me@example ", apiKey: "")
        XCTAssertFalse(monitor.isConfigured, "a login with no key is not saved")
        try monitor.saveCredentials(login: " me@example ", apiKey: " first ")
        try await waitUntilIdle(monitor, server, requests: 1)
        XCTAssertEqual(server.requests.last?.url?.query(percentEncoded: true), "login=me@example&apikey=first&search_token=BAV99&rows=25")
        XCTAssertTrue(monitor.state(for: diode).hasAnswer)

        try monitor.saveCredentials(login: "you@example", apiKey: "")
        XCTAssertFalse(monitor.state(for: diode).hasAnswer, "another login's answers are not this one's")
        try await waitUntilIdle(monitor, server, requests: 2)
        XCTAssertEqual(server.requests.last?.url?.query(percentEncoded: true), "login=you@example&apikey=first&search_token=BAV99&rows=25",
                       "the key already saved goes with the new login")

        monitor.isEnabled = false
        XCTAssertEqual(monitor.state(for: diode), .off)
        XCTAssertTrue(monitor.records.isEmpty)
        monitor.lookUp([diode])
        try await settle()
        XCTAssertEqual(server.requests.count, 2, "off, nothing is asked")

        monitor.isEnabled = true
        try await waitUntilIdle(monitor, server, requests: 3)
        try monitor.removeCredentials()
        XCTAssertEqual(monitor.state(for: diode), .notSetUp)
        XCTAssertEqual(monitor.login, "")
    }

    func testARefusedKeyStopsTheLookupsUntilItChanges() async throws {
        let refusal = #"{"itemserviceresult":{"transactionArea":[{"response":{"returnMsg":"Invalid login or apikey","success":false}}],"data":[]}}"#
        let server = ArrowStubServer { request, _ in
            request.url?.query?.contains("apikey=good") == true ? .json(ArrowFixtures.search) : .json(refusal)
        }
        let monitor = try makeMonitor(server)
        monitor.show(diode)
        monitor.show(other)
        try await waitUntilIdle(monitor, server, requests: 1)
        guard case .unavailable(let message) = monitor.state(for: diode) else {
            return XCTFail("stopped: \(monitor.state(for: diode))")
        }
        XCTAssertTrue(message.contains("Invalid login or apikey"), message)
        XCTAssertEqual(monitor.verification, .refused(message))
        monitor.lookUp([diode])
        try await settle()
        XCTAssertEqual(server.requests.count, 1, "nothing more is asked with a refused key")

        try monitor.saveCredentials(login: "me@example", apiKey: "good")
        try await waitUntilIdle(monitor, server, requests: 3)
        XCTAssertTrue(monitor.state(for: diode).hasAnswer)
        XCTAssertNil(monitor.problem)
    }

    func testAPartsArrowLinkIsItsSearchUnlessAnAnswerIsHeld() async throws {
        let server = ArrowStubServer { _, _ in .json(ArrowFixtures.search) }
        let monitor = try makeMonitor(server)
        let digiKey = HorizontalDigiKeyStockMonitor(defaults: try makeDefaults(), secrets: .memory(), cacheURL: nil)
        let mouser = HorizontalMouserStockMonitor(defaults: try makeDefaults(), secrets: .memory())
        func links(_ mpn: String) -> [HorizontalPartPageLink] {
            HorizontalPartPageLink.links(mpn: mpn, manufacturer: "Nexperia", digiKey: digiKey, mouser: mouser, arrow: monitor)
        }

        XCTAssertEqual(links(" BAV99 ").map(\.title), ["Open on DigiKey", "Open on Mouser", "Open on Arrow"])
        XCTAssertEqual(links("AB+C#1").last?.url.absoluteString, "https://www.arrow.com/en/products/search?q=AB%2BC%231")
        XCTAssertTrue(server.requests.isEmpty, "a link asks Arrow nothing")

        monitor.lookUp([diode])
        try await waitUntilIdle(monitor, server, requests: 1)
        XCTAssertEqual(links("BAV99").last?.url.absoluteString, "https://www.arrow.com/en/products/bav99/nexperia")

        monitor.isEnabled = false
        XCTAssertEqual(links("BAV99").map(\.title), ["Open on DigiKey", "Open on Mouser"], "none while Arrow is off")
    }

    /// The cell's tooltip credits Arrow, and says what its other sites have.
    func testTheCellCreditsArrow() async throws {
        let server = ArrowStubServer { _, _ in .json(ArrowFixtures.search) }
        let monitor = try makeMonitor(server)
        monitor.lookUp([diode])
        try await waitUntilIdle(monitor, server, requests: 1)
        let part = HorizontalPoolPart(id: "p", mpn: "BAV99", manufacturer: "Nexperia", partDescription: "", packageName: "",
                                      tags: [], value: "", displayValue: "BAV99", entityID: nil, refdesPrefix: "D", gates: [])
        let help = monitor.state(for: diode).help(for: part)
        XCTAssertTrue(help.contains("Nexperia BAV99 at Arrow"), help)
        XCTAssertTrue(help.contains("\(21_000.formatted()) in stock"), help)
        XCTAssertTrue(help.contains("Verical: \(9000.formatted())"), help)
        XCTAssertTrue(help.contains("Stock data from Arrow Electronics."), help)
        XCTAssertNotNil(HorizontalStockCheck.arrow(monitor.state(for: diode)) {})
        XCTAssertEqual(HorizontalStockCheck.arrow(monitor.state(for: diode)) {}?.title, "Check Arrow Stock Again")
        XCTAssertNil(HorizontalStockCheck.arrow(.notSetUp) {})
    }
}

/// An answer in the shape Arrow's documentation gives for the token search:
/// BAV99 from two makers and, as a prefix search brings, BAV99W.
private enum ArrowFixtures {
    static let search = #"""
    {"itemserviceresult":{
      "transactionArea":[{"response":{"returnCode":"0","returnMsg":"","success":true}}],
      "data":[{
        "resources":[{"type":"search","uri":"https://www.arrow.com/en/products/search?q=bav99"}],
        "PartList":[
          {"itemId":1,"partNum":"BAV99","manufacturer":{"mfrCd":"NEXPERIA","mfrName":"Nexperia"},
           "resources":[{"type":"cloud_part_detail","uri":"https://www.arrow.com/en/products/bav99/nexperia"}],
           "InvOrg":{"webSites":[
             {"code":"arrow.com","name":"arrow.com","sources":[
               {"currency":"USD","sourceCd":"ACNA","sourceParts":[
                 {"Availability":[{"fohQty":15000,"availabilityCd":"INSTK"}],"inStock":true,"mfrLeadTime":8},
                 {"Availability":[{"fohQty":"6000","availabilityCd":"INSTK"}],"inStock":true}]}]},
             {"code":"Verical.com","name":"Verical","sources":[
               {"currency":"USD","sourceCd":"VERICAL","sourceParts":[
                 {"Availability":[{"fohQty":9000}],"inStock":true}]}]}]}},
          {"itemId":2,"partNum":"BAV99","manufacturer":{"mfrCd":"ONSEMI","mfrName":"onsemi"},
           "resources":[],
           "InvOrg":{"webSites":[
             {"code":"arrow.com","name":"arrow.com","sources":[
               {"sourceParts":[
                 {"Availability":[{"fohQty":500}],
                  "resources":[{"type":"detail","uri":"https://www.arrow.com/en/products/bav99/onsemi"}]}]}]}]}},
          {"itemId":3,"partNum":"BAV99W","manufacturer":{"mfrCd":"NEXPERIA","mfrName":"Nexperia"},
           "resources":[{"type":"cloud_part_detail","uri":"https://www.arrow.com/en/products/bav99w/nexperia"}],
           "InvOrg":{"webSites":[
             {"code":"arrow.com","name":"arrow.com","sources":[
               {"sourceParts":[{"Availability":[{"fohQty":0,"availabilityCd":"NOSTK"}],"inStock":false}]}]}]}}
        ]
      }]
    }}
    """#
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

/// An Arrow that answers from a closure and records what it was asked.
private final class ArrowStubServer: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]

        static func json(_ text: String) -> Reply { Reply(status: 200, body: Data(text.utf8)) }
        static func status(_ status: Int, _ text: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: headers)
        }
    }

    // Guarded by `lock`.
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let respond: @Sendable (URLRequest, Int) -> Reply
    let id = UUID().uuidString

    init(_ respond: @escaping @Sendable (URLRequest, Int) -> Reply) {
        self.respond = respond
        ArrowStubProtocol.register(self)
    }

    deinit {
        ArrowStubProtocol.unregister(id)
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func handle(_ request: URLRequest) -> Reply {
        let count = lock.withLock {
            recorded.append(request)
            return recorded.count - 1
        }
        return respond(request, count)
    }

    func client(login: String = "me@example", apiKey: String = "key") -> HorizontalArrowClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArrowStubProtocol.self]
        configuration.httpAdditionalHeaders = [ArrowStubProtocol.serverHeader: id]
        return HorizontalArrowClient(credentials: .init(login: login, apiKey: apiKey),
                                     session: URLSession(configuration: configuration), requestSpacing: .zero)
    }
}

private final class ArrowStubProtocol: URLProtocol {
    static let serverHeader = "X-Stub-Server"
    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var servers: [String: ArrowStubServer] = [:]

    static func register(_ server: ArrowStubServer) {
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
        let reply = server.handle(request)
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
