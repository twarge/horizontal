import Foundation
import XCTest
@testable import HorizontalNative

/// The Parts pane's DigiKey Stock column: DigiKey's Product Information API
/// v4 as the client signs in to it and reads it, against a stub server, and
/// the monitor that asks it once and keeps the answers.
final class HorizontalDigiKeyClientTests: XCTestCase {
    func testThePricingSearchAnswersWithThePartsManufacturersProduct() throws {
        let products = try JSONDecoder().decode(PricingFixture.self, from: DigiKeyFixtures.pricing).ProductPricings

        guard case .stocked(let ti) = HorizontalDigiKeyClient.answer(for: products, mpn: "lm358dr", manufacturer: "Texas Instruments") else {
            return XCTFail("TI's LM358DR is stocked")
        }
        XCTAssertEqual(ti.quantityAvailable, 51234)
        XCTAssertEqual(ti.manufacturer, "Texas Instruments")
        XCTAssertEqual(ti.productURL?.absoluteString, "https://www.digikey.com/en/products/detail/texas-instruments/LM358DR/555886")
        XCTAssertEqual(ti.variations.map(\.digiKeyProductNumber), ["296-1014-1-ND", "296-1014-2-ND"])
        XCTAssertEqual(ti.variations.map(\.packageType), ["Cut Tape (CT)", "Tape & Reel (TR)"])
        XCTAssertEqual(ti.manufacturerLeadWeeks, "6")
        XCTAssertFalse(ti.matchedByMPNOnly)

        guard case .stocked(let st) = HorizontalDigiKeyClient.answer(for: products, mpn: "LM358DR", manufacturer: "ST Microelectronics") else {
            return XCTFail("ST's LM358DR is stocked")
        }
        XCTAssertEqual(st.quantityAvailable, 0)
        XCTAssertTrue(st.isObsolete, "a product status of Obsolete")
        XCTAssertFalse(st.matchedByMPNOnly)

        guard case .stocked(let unknown) = HorizontalDigiKeyClient.answer(for: products, mpn: "LM358DR", manufacturer: "Onsemi") else {
            return XCTFail("an MPN DigiKey has from other makers still answers")
        }
        XCTAssertEqual(unknown.quantityAvailable, 51234, "the most stocked of them")
        XCTAssertTrue(unknown.matchedByMPNOnly)

        XCTAssertEqual(HorizontalDigiKeyClient.answer(for: products, mpn: "LM358", manufacturer: "Texas Instruments"), .notCarried,
                       "products the MPN is only the start of answer nothing")
    }

    /// DigiKey can report a product's own count as 0 while its packagings
    /// have stock (Stackpole's RMCF0402FT15K0, as it answered), so the count
    /// is a packaging's.
    func testTheCountIsThePackagingsNotTheProducts() throws {
        let products = try JSONDecoder().decode(PricingFixture.self, from: DigiKeyFixtures.resistor).ProductPricings
        guard case .stocked(let stock) = HorizontalDigiKeyClient.answer(for: products, mpn: "RMCF0402FT15K0", manufacturer: "Stackpole") else {
            return XCTFail("stocked")
        }
        XCTAssertEqual(stock.quantityAvailable, 0, "as DigiKey sends it")
        guard case .stocked(let unknownMaker) = HorizontalDigiKeyClient.answer(for: products, mpn: "RMCF0402FT15K0", manufacturer: "Nobody") else {
            return XCTFail("stocked")
        }
        XCTAssertEqual(unknownMaker.manufacturer, "Stackpole Electronics Inc", "the product with the most in any packaging")

        let mostStocked = stock.selection(for: .any)
        XCTAssertEqual(mostStocked.quantity, 54820)
        XCTAssertFalse(mostStocked.isFallback)
        XCTAssertEqual(stock.selection(for: .cutTape).variation?.digiKeyProductNumber, "RMCF0402FT15K0CT-ND")
        XCTAssertEqual(stock.selection(for: .cutTape).quantity, 54820)
        XCTAssertEqual(stock.selection(for: .tapeAndReel).variation?.digiKeyProductNumber, "RMCF0402FT15K0TR-ND")
        XCTAssertEqual(stock.selection(for: .tapeAndReel).quantity, 50000)
        XCTAssertEqual(stock.selection(for: .digiReel).variation?.digiKeyProductNumber, "RMCF0402FT15K0DKR-ND")

        let cell = HorizontalDigiKeyStockMonitor.CellState.answer(.stocked(stock), checkedAt: Date(), isRefreshing: false, packaging: .any)
        XCTAssertEqual(cell.title, 54820.formatted())
        XCTAssertFalse(cell.isWarning)
        let part = DigiKeyFixtures.part(mpn: "RMCF0402FT15K0", manufacturer: "Stackpole")
        let help = cell.help(for: part)
        XCTAssertTrue(help.contains("Showing Cut Tape (CT): \(54820.formatted())"), "cut tape, of two with the same: \(help)")
        XCTAssertFalse(help.contains("lead time"), "there is stock")
        XCTAssertTrue(help.contains("Click to open the part on DigiKey."))
    }

    func testAPartNotSoldInThePackagingCountsItsMostStockedOne() throws {
        let products = try JSONDecoder().decode(PricingFixture.self, from: DigiKeyFixtures.tubeOnly).ProductPricings
        guard case .stocked(let stock) = HorizontalDigiKeyClient.answer(for: products, mpn: "OPA2189IDR", manufacturer: "Texas Instruments") else {
            return XCTFail("stocked")
        }
        let selection = stock.selection(for: .cutTape)
        XCTAssertTrue(selection.isFallback)
        XCTAssertEqual(selection.variation?.digiKeyProductNumber, "296-OPA2189ID-ND", "DigiKey's own stock before a Marketplace seller's larger one")
        XCTAssertEqual(selection.quantity, 812)

        let cell = HorizontalDigiKeyStockMonitor.CellState.answer(.stocked(stock), checkedAt: Date(), isRefreshing: false, packaging: .cutTape)
        XCTAssertEqual(cell.title, 812.formatted())
        XCTAssertTrue(cell.help(for: DigiKeyFixtures.part(mpn: "OPA2189IDR", manufacturer: "Texas Instruments"))
            .contains("Not sold as Cut Tape; showing Tube: \(812.formatted())"))
    }

    func testAPackagingIsKnownByItsPartNumberWhereDigiKeyNamesNone() {
        let unnamed = HorizontalDigiKeyStock.Variation(digiKeyProductNumber: "311-10.0KLRCT-ND", packageType: "", quantityAvailable: 1)
        XCTAssertTrue(HorizontalDigiKeyPackaging.cutTape.matches(unnamed))
        XCTAssertFalse(HorizontalDigiKeyPackaging.tapeAndReel.matches(unnamed))
        let reel = HorizontalDigiKeyStock.Variation(digiKeyProductNumber: "311-10.0KLRDKR-ND", packageType: "", quantityAvailable: 1)
        XCTAssertTrue(HorizontalDigiKeyPackaging.digiReel.matches(reel))
        XCTAssertFalse(HorizontalDigiKeyPackaging.tapeAndReel.matches(reel))
    }

    func testManufacturersMatchWhenOneNameHoldsTheOther() {
        XCTAssertTrue(HorizontalPartQuery.manufacturersMatch("Murata", "Murata Electronics"))
        XCTAssertTrue(HorizontalPartQuery.manufacturersMatch("Maxim Integrated", "Analog Devices Inc./Maxim Integrated"))
        XCTAssertTrue(HorizontalPartQuery.manufacturersMatch("STMicroelectronics", "ST Microelectronics"))
        XCTAssertFalse(HorizontalPartQuery.manufacturersMatch("TI", "Texas Instruments"), "too short to match")
        XCTAssertFalse(HorizontalPartQuery.manufacturersMatch("Vishay", "Yageo"))
    }

    func testAnMPNRidesInThePathAsOneSegment() async {
        XCTAssertEqual(HorizontalDigiKeyClient.pathSegment("MCP2221A-I/SL"), "MCP2221A-I%2FSL")
        XCTAssertEqual(HorizontalDigiKeyClient.pathSegment("LT1763CS8#PBF"), "LT1763CS8%23PBF")
        XCTAssertEqual(HorizontalDigiKeyClient.pathSegment("GRM155R71C104KA88D"), "GRM155R71C104KA88D")
        let client = HorizontalDigiKeyClient(credentials: .init(clientID: "id", clientSecret: "secret"), site: "US")
        let request = await client.pricingRequest(mpn: "MCP2221A-I/SL")
        XCTAssertEqual(request.url?.absoluteString, "https://api.digikey.com/products/v4/search/MCP2221A-I%2FSL/pricing?limit=10")
    }

    func testOneSignInServesEveryLookup() async throws {
        let server = DigiKeyStubServer { request, _ in
            if request.url?.path == "/v1/oauth2/token" {
                return .json(#"{"access_token":"token-1","expires_in":599,"token_type":"Bearer"}"#)
            }
            return .json(DigiKeyFixtures.pricing)
        }
        let client = server.client()

        let first = try await client.answer(mpn: "LM358DR", manufacturer: "Texas Instruments")
        let second = try await client.answer(mpn: "LM358DR", manufacturer: "STMicroelectronics")
        guard case .stocked(let ti) = first, case .stocked(let st) = second else {
            return XCTFail("both stocked")
        }
        XCTAssertEqual(ti.quantityAvailable, 51234)
        XCTAssertEqual(st.quantityAvailable, 0)

        let requests = server.requests
        XCTAssertEqual(requests.map { $0.request.url?.path }, [
            "/v1/oauth2/token",
            "/products/v4/search/LM358DR/pricing",
            "/products/v4/search/LM358DR/pricing"
        ])
        let signIn = try XCTUnwrap(requests.first)
        XCTAssertEqual(signIn.request.httpMethod, "POST")
        XCTAssertEqual(signIn.request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(signIn.body.map { String(decoding: $0, as: UTF8.self) },
                       "client_id=client%20id&client_secret=s%26cret%3D&grant_type=client_credentials")
        for lookup in requests.dropFirst() {
            XCTAssertEqual(lookup.request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            XCTAssertEqual(lookup.request.value(forHTTPHeaderField: "X-DIGIKEY-Client-Id"), "client id")
            XCTAssertEqual(lookup.request.value(forHTTPHeaderField: "X-DIGIKEY-Locale-Site"), "US")
        }
    }

    func testATokenDigiKeyNoLongerTakesIsReplacedOnce() async throws {
        let server = DigiKeyStubServer { request, count in
            if request.url?.path == "/v1/oauth2/token" {
                return .json(#"{"access_token":"token-\#(count)","expires_in":599}"#)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer token-0"
                ? .status(401, #"{"title":"Unauthorized"}"#)
                : .json(DigiKeyFixtures.pricing)
        }
        let answer = try await server.client().answer(mpn: "LM358DR", manufacturer: "Texas Instruments")
        guard case .stocked = answer else { return XCTFail("stocked after a new token") }
        XCTAssertEqual(server.requests.map { $0.request.url?.path }, [
            "/v1/oauth2/token", "/products/v4/search/LM358DR/pricing",
            "/v1/oauth2/token", "/products/v4/search/LM358DR/pricing"
        ])
    }

    func testRefusalsAndRateLimitsAreTheirOwnFailures() async throws {
        // The sign-in's own error shape, as DigiKey sends it.
        let refused = DigiKeyStubServer { _, _ in
            .status(401, #"{"ErrorResponseVersion":"3.0.0.0","StatusCode": 401,"ErrorMessage":"Invalid clientId","ErrorDetails":"client_id form parameter has  incorrect value. Send valid client_id","ValidationErrors":[]}"#)
        }
        do {
            _ = try await refused.client().answer(mpn: "LM358DR", manufacturer: "")
            XCTFail("refused")
        } catch let failure as HorizontalDigiKeyClient.Failure {
            XCTAssertEqual(failure, .unauthorized("DigiKey didn't accept the client ID and secret (Invalid clientId)."))
        }

        let limited = DigiKeyStubServer { request, _ in
            request.url?.path == "/v1/oauth2/token"
                ? .json(#"{"access_token":"t","expires_in":599}"#)
                : .status(429, #"{"title":"Too Many Requests"}"#, headers: ["Retry-After": "30"])
        }
        do {
            _ = try await limited.client().answer(mpn: "LM358DR", manufacturer: "")
            XCTFail("limited")
        } catch let failure as HorizontalDigiKeyClient.Failure {
            XCTAssertEqual(failure, .rateLimited(retryAfter: 30))
            XCTAssertEqual(failure.message, "DigiKey's rate limit was reached. Try again in 30 seconds.")
        }
    }

    func testAnMPNThePathCannotCarryIsSearchedByKeyword() async throws {
        let server = DigiKeyStubServer { request, _ in
            switch request.url?.path {
            case "/v1/oauth2/token": .json(#"{"access_token":"t","expires_in":599}"#)
            case "/products/v4/search/keyword": .json(DigiKeyFixtures.keyword)
            default: .status(404, #"{"title":"Not Found"}"#)
            }
        }
        let answer = try await server.client().answer(mpn: "MCP2221A-I/SL", manufacturer: "Microchip Technology")
        guard case .stocked(let stock) = answer else { return XCTFail("found by keyword") }
        XCTAssertEqual(stock.quantityAvailable, 7321)
        XCTAssertTrue(stock.isEndOfLife)
        XCTAssertEqual(stock.variations.first?.isMarketplace, true)

        let keyword = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(keyword.request.httpMethod, "POST")
        let body = try XCTUnwrap(keyword.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["Keywords"] as? String, "MCP2221A-I/SL")
        XCTAssertEqual(body["Limit"] as? Int, 10)
    }

    func testAnMPNDigiKeyHasNothingUnderIsNotCarried() async throws {
        let server = DigiKeyStubServer { request, _ in
            request.url?.path == "/v1/oauth2/token"
                ? .json(#"{"access_token":"t","expires_in":599}"#)
                : .status(404, #"{"title":"Not Found"}"#)
        }
        let answer = try await server.client().answer(mpn: "NOT-A-PART", manufacturer: "")
        XCTAssertEqual(answer, .notCarried)
        XCTAssertEqual(server.requests.count, 2, "no keyword search for an MPN the path carries")
    }
}

@MainActor
final class HorizontalDigiKeyStockMonitorTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "horizontal-digikey-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func makeCacheURL() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("digikey-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("digikey-stock.json")
    }

    private func waitUntilIdle(_ monitor: HorizontalDigiKeyStockMonitor) async throws {
        for _ in 0..<500 where !monitor.checking.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(monitor.checking.isEmpty, "the lookups finished")
    }

    func testAPartIsAskedAboutOnceAndItsAnswerKept() async throws {
        let server = DigiKeyStubServer { request, _ in
            switch request.url?.path {
            case "/v1/oauth2/token": .json(#"{"access_token":"t","expires_in":599}"#)
            case "/products/v4/search/LM358DR/pricing": .json(DigiKeyFixtures.pricing)
            default: .status(404, #"{"title":"Not Found"}"#)
            }
        }
        let defaults = try makeDefaults()
        let cacheURL = makeCacheURL()
        let monitor = HorizontalDigiKeyStockMonitor(defaults: defaults, secrets: .memory(), cacheURL: cacheURL, makeClient: server.client(credentials:))
        let opAmp = DigiKeyFixtures.part(mpn: "LM358DR", manufacturer: "Texas Instruments")
        let missing = DigiKeyFixtures.part(mpn: "NOT-A-PART", manufacturer: "Nobody")
        let blank = DigiKeyFixtures.part(mpn: " ", manufacturer: "Nobody")

        XCTAssertEqual(monitor.state(for: opAmp), .notSetUp)
        monitor.lookUp([opAmp])
        XCTAssertTrue(server.requests.isEmpty, "nothing is asked without credentials")

        try monitor.saveCredentials(clientID: "id", clientSecret: "secret")
        XCTAssertTrue(monitor.isConfigured)
        XCTAssertEqual(defaults.string(forKey: HorizontalDigiKeyStockMonitor.clientIDKey), "id")
        XCTAssertEqual(monitor.state(for: opAmp), .pending)

        monitor.lookUp([opAmp, missing, blank, opAmp])
        XCTAssertEqual(monitor.state(for: opAmp), .checking)
        XCTAssertEqual(monitor.state(for: blank), .noMPN)
        try await waitUntilIdle(monitor)

        guard case .answer(.stocked(let stock), _, false, .any) = monitor.state(for: opAmp) else {
            return XCTFail("stocked: \(monitor.state(for: opAmp))")
        }
        XCTAssertEqual(stock.quantityAvailable, 51234)
        XCTAssertEqual(monitor.state(for: opAmp).title, 40000.formatted(), "the most stocked packaging, by default")
        guard case .answer(.notCarried, _, _, _) = monitor.state(for: missing) else {
            return XCTFail("not carried: \(monitor.state(for: missing))")
        }
        let asked = server.requests.count
        XCTAssertEqual(asked, 3, "a sign-in and one request per MPN")

        monitor.packaging = .tapeAndReel
        XCTAssertEqual(monitor.state(for: opAmp).title, 11234.formatted())
        XCTAssertEqual(defaults.string(forKey: HorizontalDigiKeyStockMonitor.packagingKey), "tapeAndReel")
        XCTAssertEqual(server.requests.count, asked, "another packaging asks DigiKey nothing")

        monitor.lookUp([opAmp, missing])
        XCTAssertEqual(server.requests.count, asked, "fresh answers are not asked for again")
        monitor.lookUp([opAmp], force: true)
        try await waitUntilIdle(monitor)
        XCTAssertEqual(server.requests.count, asked + 1, "unless forced")

        // The answers are on disk for the next launch.
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: cacheURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let relaunched = HorizontalDigiKeyStockMonitor(defaults: defaults, secrets: .memory("secret"), cacheURL: cacheURL, makeClient: server.client(credentials:))
        XCTAssertEqual(relaunched.records.count, 2)
        guard case .answer(.stocked, _, _, .tapeAndReel) = relaunched.state(for: opAmp) else {
            return XCTFail("kept, with the packaging: \(relaunched.state(for: opAmp))")
        }
    }

    func testARefusalStopsTheLookupsUntilTheCredentialsChange() async throws {
        let server = DigiKeyStubServer { request, _ in
            request.url?.path == "/v1/oauth2/token"
                ? .json(#"{"access_token":"t","expires_in":599}"#)
                : .status(403, #"{"title":"Forbidden","detail":"The app is not subscribed to this API."}"#)
        }
        let monitor = HorizontalDigiKeyStockMonitor(defaults: try makeDefaults(), secrets: .memory("secret"), cacheURL: nil, makeClient: server.client(credentials:))
        try monitor.saveCredentials(clientID: "id", clientSecret: nil)
        let part = DigiKeyFixtures.part(mpn: "LM358DR", manufacturer: "Texas Instruments")

        monitor.lookUp([part])
        try await waitUntilIdle(monitor)
        let message = "DigiKey refused the request: The app is not subscribed to this API."
        XCTAssertEqual(monitor.problem, message)
        XCTAssertEqual(monitor.verification, .refused(message))
        XCTAssertEqual(monitor.state(for: part), .unavailable(message))

        let asked = server.requests.count
        monitor.lookUp([part], force: true)
        XCTAssertEqual(server.requests.count, asked, "stopped")

        try monitor.saveCredentials(clientID: "other", clientSecret: nil)
        XCTAssertNil(monitor.problem)
        monitor.lookUp([part])
        try await waitUntilIdle(monitor)
        XCTAssertGreaterThan(server.requests.count, asked, "new credentials start over")
    }

    /// Settings' switch: off, nothing is asked, nothing shows (the Parts
    /// pane's column and both panes' menu items go by the state), and it
    /// stays off at the next launch; on again, the lookups resume.
    func testTheSwitchTurnsEverythingOff() async throws {
        let server = DigiKeyStubServer { request, _ in
            switch request.url?.path {
            case "/v1/oauth2/token": .json(#"{"access_token":"t","expires_in":599}"#)
            case "/products/v4/search/LM358DR/pricing": .json(DigiKeyFixtures.pricing)
            default: .status(404, #"{"title":"Not Found"}"#)
            }
        }
        let defaults = try makeDefaults()
        let monitor = HorizontalDigiKeyStockMonitor(defaults: defaults, secrets: .memory("secret"), cacheURL: nil, makeClient: server.client(credentials:))
        XCTAssertTrue(monitor.isEnabled, "on until turned off")
        try monitor.saveCredentials(clientID: "id", clientSecret: nil)
        let opAmp = DigiKeyFixtures.part(mpn: "LM358DR", manufacturer: "Texas Instruments")

        monitor.isEnabled = false
        XCTAssertEqual(monitor.state(for: opAmp), .off)
        XCTAssertNil(monitor.state(for: opAmp).productURL)
        monitor.lookUp([opAmp], force: true)
        await monitor.verifyCredentials()
        XCTAssertTrue(server.requests.isEmpty, "no request of any kind while off")
        XCTAssertNil(monitor.verification)
        let relaunched = HorizontalDigiKeyStockMonitor(defaults: defaults, secrets: .memory("secret"), cacheURL: nil, makeClient: server.client(credentials:))
        XCTAssertFalse(relaunched.isEnabled, "kept between launches")

        monitor.isEnabled = true
        monitor.lookUp([opAmp])
        XCTAssertEqual(monitor.state(for: opAmp), .checking)
        monitor.isEnabled = false
        XCTAssertTrue(monitor.checking.isEmpty, "turning it off stops what is in flight")
        monitor.isEnabled = true
        monitor.lookUp([opAmp])
        try await waitUntilIdle(monitor)
        XCTAssertNotNil(monitor.state(for: opAmp).productURL, "on again, the part's page is known")
    }

    /// A part's Open on DigiKey, on the canvases and in the panes: DigiKey's
    /// search for its MPN until the API has answered, then the product page
    /// it answered with, which stays once the credentials go; none while
    /// DigiKey is off, or for a part with no MPN.
    func testAPartsDigiKeyLinkIsItsSearchUntilDigiKeyAnswers() async throws {
        let server = DigiKeyStubServer { request, _ in
            switch request.url?.path {
            case "/v1/oauth2/token": .json(#"{"access_token":"t","expires_in":599}"#)
            case "/products/v4/search/LM358DR/pricing": .json(DigiKeyFixtures.pricing)
            default: .status(404, #"{"title":"Not Found"}"#)
            }
        }
        let monitor = HorizontalDigiKeyStockMonitor(defaults: try makeDefaults(), secrets: .memory(), cacheURL: nil, makeClient: server.client(credentials:))
        // Mouser's own link is HorizontalMouserStockMonitorTests'.
        let mouser = HorizontalMouserStockMonitor(defaults: try makeDefaults(), secrets: .memory())
        mouser.isEnabled = false
        func links(_ mpn: String, _ manufacturer: String = "Texas Instruments") -> [HorizontalPartPageLink] {
            HorizontalPartPageLink.links(mpn: mpn, manufacturer: manufacturer, digiKey: monitor, mouser: mouser)
        }

        let search = links(" LM358DR ")
        XCTAssertEqual(search.map(\.title), ["Open on DigiKey"], "no credentials needed")
        XCTAssertEqual(search.first?.url.absoluteString, "https://www.digikey.com/en/products/result?keywords=LM358DR")
        XCTAssertEqual(links("AB+C#1/2&x=y").first?.url.absoluteString,
                       "https://www.digikey.com/en/products/result?keywords=AB%2BC%231/2%26x%3Dy",
                       "an MPN reaches the search as itself")
        XCTAssertEqual(links(" "), [], "no MPN, no link")
        XCTAssertTrue(server.requests.isEmpty, "a link asks DigiKey nothing")

        try monitor.saveCredentials(clientID: "id", clientSecret: "secret")
        monitor.lookUp([HorizontalPartQuery(mpn: "LM358DR", manufacturer: "Texas Instruments")])
        try await waitUntilIdle(monitor)
        let page = "https://www.digikey.com/en/products/detail/texas-instruments/LM358DR/555886"
        XCTAssertEqual(links("LM358DR").first?.url.absoluteString, page, "the page DigiKey answered with")
        XCTAssertEqual(links("LM358DR", "Onsemi").first?.url.absoluteString,
                       "https://www.digikey.com/en/products/result?keywords=LM358DR",
                       "another maker's part is not the one DigiKey answered about")

        try monitor.removeCredentials()
        XCTAssertEqual(links("LM358DR").first?.url.absoluteString, page, "the page outlasts the credentials")

        monitor.isEnabled = false
        XCTAssertEqual(links("LM358DR"), [], "none while DigiKey is off")
    }

    /// A Pools pane part is asked about by its MPN, a derived part's from its
    /// base, never by the name a part without an MPN shows (its value).
    func testAPoolPartIsAskedAboutByItsMPN() {
        func item(_ category: HorizontalPoolItemCategory, name: String, mpn: String) -> HorizontalPoolLibraryItem {
            HorizontalPoolLibraryItem(
                id: name, uuid: name, name: name, detail: "", tags: "", category: category, poolName: "Pool",
                poolURL: URL(fileURLWithPath: "/pool"), url: URL(fileURLWithPath: "/pool/\(name).json"),
                manufacturer: "Texas Instruments", mpn: mpn
            )
        }
        XCTAssertEqual(HorizontalPartQuery(item: item(.part, name: "LM358DR", mpn: "LM358DR")).mpn, "LM358DR")
        XCTAssertEqual(HorizontalPartQuery(item: item(.part, name: "10k", mpn: "")).mpn, "", "a value is no MPN")
        XCTAssertEqual(HorizontalPartQuery(item: item(.package, name: "SOIC-8", mpn: "SOIC-8")).mpn, "")
        XCTAssertEqual(HorizontalPartQuery(item: item(.part, name: "LM358DR", mpn: "LM358DR")).manufacturer, "Texas Instruments")

        let base = HorizontalPoolLibraryItem(
            id: "base", uuid: "base", name: "LM358", detail: "", tags: "", category: .part, poolName: "Pool",
            poolURL: URL(fileURLWithPath: "/pool"), url: URL(fileURLWithPath: "/pool/base.json"), mpn: "LM358",
            partRecord: HorizontalPartRecord(json: ["type": "part", "uuid": "base", "MPN": [false, "LM358"], "manufacturer": [false, "TI"]])
        )
        let derived = HorizontalPoolLibraryItem(
            id: "derived", uuid: "derived", name: "", detail: "", tags: "", category: .part, poolName: "Pool",
            poolURL: URL(fileURLWithPath: "/pool"), url: URL(fileURLWithPath: "/pool/derived.json"),
            partRecord: HorizontalPartRecord(json: ["type": "part", "uuid": "derived", "base": "base", "MPN": [true, ""], "manufacturer": [true, ""]])
        )
        let resolved = HorizontalPoolLibrary.resolvingInheritance([base, derived])
        XCTAssertEqual(resolved.last.map(HorizontalPartQuery.init(item:))?.mpn, "LM358", "inherited through the base")
    }

    func testRemovingTheCredentialsForgetsTheSecret() throws {
        let secrets = HorizontalSecretStore.memory()
        let monitor = HorizontalDigiKeyStockMonitor(defaults: try makeDefaults(), secrets: secrets, cacheURL: nil)
        try monitor.saveCredentials(clientID: " id ", clientSecret: " secret ")
        XCTAssertEqual(monitor.clientID, "id")
        XCTAssertEqual(secrets.read(), "secret")
        try monitor.removeCredentials()
        XCTAssertFalse(monitor.isConfigured)
        XCTAssertNil(secrets.read())
        XCTAssertEqual(monitor.clientID, "")
    }
}

private struct PricingFixture: Decodable {
    var ProductPricings: [HorizontalDigiKeyClient.Product]
}

private enum DigiKeyFixtures {
    static let pricing = Data(#"""
    {
      "ProductPricings": [
        {
          "ManufacturerProductNumber": "LM358DR",
          "Manufacturer": {"Id": 296, "Name": "Texas Instruments"},
          "Description": {"ProductDescription": "IC OPAMP GP 2 CIRCUIT 8SOIC"},
          "QuantityAvailable": 51234,
          "ProductUrl": "https://www.digikey.com/en/products/detail/texas-instruments/LM358DR/555886",
          "IsDiscontinued": false,
          "IsObsolete": false,
          "IsEndOfLife": false,
          "NormallyStocking": true,
          "ManufacturerLeadWeeks": "6",
          "ProductVariations": [
            {"DigiKeyProductNumber": "296-1014-1-ND", "QuantityAvailableforPackageType": 40000,
             "PackageType": {"Id": 2, "Name": "Cut Tape (CT)"}, "MarketPlace": false,
             "StandardPricing": [{"BreakQuantity": 1, "UnitPrice": 0.42, "TotalPrice": 0.42}]},
            {"DigiKeyProductNumber": "296-1014-2-ND", "QuantityAvailableforPackageType": 11234,
             "PackageType": {"Id": 1, "Name": "Tape & Reel (TR)"}, "MarketPlace": false}
          ]
        },
        {
          "ManufacturerProductNumber": "LM358DR",
          "Manufacturer": {"Id": 497, "Name": "STMicroelectronics"},
          "QuantityAvailable": 0,
          "ProductStatus": {"Id": 4, "Status": "Obsolete"},
          "ProductVariations": []
        },
        {
          "ManufacturerProductNumber": "LM358DRG4",
          "Manufacturer": {"Id": 296, "Name": "Texas Instruments"},
          "QuantityAvailable": 100000
        }
      ],
      "ProductsCount": 3
    }
    """#.utf8)

    /// Stackpole's RMCF0402FT15K0 as DigiKey answered: no count of its own.
    static let resistor = Data(#"""
    {
      "ProductPricings": [
        {
          "ManufacturerProductNumber": "RMCF0402FT15K0",
          "Manufacturer": {"Id": 738, "Name": "Stackpole Electronics Inc"},
          "QuantityAvailable": 0,
          "ProductUrl": "https://www.digikey.com/en/products/detail/stackpole-electronics-inc/RMCF0402FT15K0/1712506",
          "ManufacturerLeadWeeks": "22",
          "ProductVariations": [
            {"DigiKeyProductNumber": "RMCF0402FT15K0DKR-ND", "QuantityAvailableforPackageType": 54820,
             "PackageType": {"Id": 243, "Name": "Digi-Reel®"}, "MarketPlace": false},
            {"DigiKeyProductNumber": "RMCF0402FT15K0TR-ND", "QuantityAvailableforPackageType": 50000,
             "PackageType": {"Id": 1, "Name": "Tape & Reel (TR)"}, "MarketPlace": false},
            {"DigiKeyProductNumber": "RMCF0402FT15K0CT-ND", "QuantityAvailableforPackageType": 54820,
             "PackageType": {"Id": 2, "Name": "Cut Tape (CT)"}, "MarketPlace": false}
          ]
        },
        {
          "ManufacturerProductNumber": "RMCF0402FT15K0",
          "Manufacturer": {"Id": 9999, "Name": "Some Reseller"},
          "QuantityAvailable": 100
        }
      ]
    }
    """#.utf8)

    /// A part sold in tubes only, with a Marketplace seller holding more.
    static let tubeOnly = Data(#"""
    {
      "ProductPricings": [
        {
          "ManufacturerProductNumber": "OPA2189IDR",
          "Manufacturer": {"Id": 296, "Name": "Texas Instruments"},
          "QuantityAvailable": 0,
          "ProductVariations": [
            {"DigiKeyProductNumber": "296-OPA2189ID-ND", "QuantityAvailableforPackageType": 812,
             "PackageType": {"Id": 4, "Name": "Tube"}, "MarketPlace": false},
            {"DigiKeyProductNumber": "2156-OPA2189ID-ND", "QuantityAvailableforPackageType": 5000,
             "PackageType": {"Id": 4, "Name": "Tube"}, "MarketPlace": true}
          ]
        }
      ]
    }
    """#.utf8)

    static let keyword = Data(#"""
    {
      "Products": [
        {"ManufacturerProductNumber": "MCP2221A-I/SLVAO", "Manufacturer": {"Id": 150, "Name": "Microchip Technology"}, "QuantityAvailable": 5}
      ],
      "ExactMatches": [
        {
          "ManufacturerProductNumber": "MCP2221A-I/SL",
          "Manufacturer": {"Id": 150, "Name": "Microchip Technology"},
          "QuantityAvailable": 7321,
          "EndOfLife": true,
          "Discontinued": false,
          "ProductStatus": {"Id": 0, "Status": "Active"},
          "ProductVariations": [
            {"DigiKeyProductNumber": "MCP2221A-I/SL-ND", "QuantityAvailableforPackageType": 7321,
             "PackageType": {"Id": 3, "Name": "Tube"}, "MarketPlace": true}
          ]
        }
      ],
      "ProductsCount": 2
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

/// A DigiKey that answers from a closure and records what it was asked:
/// each request with its body, and how many came before it.
private final class DigiKeyStubServer: @unchecked Sendable {
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
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private let respond: @Sendable (URLRequest, Int) -> Reply
    let id = UUID().uuidString

    init(_ respond: @escaping @Sendable (URLRequest, Int) -> Reply) {
        self.respond = respond
        DigiKeyStubProtocol.register(self)
    }

    deinit {
        DigiKeyStubProtocol.unregister(id)
    }

    var requests: [Recorded] {
        lock.withLock { recorded }
    }

    func handle(_ request: URLRequest, body: Data?) -> Reply {
        let count = lock.withLock {
            recorded.append(Recorded(request: request, body: body))
            return recorded.count - 1
        }
        return respond(request, count)
    }

    func client(credentials: HorizontalDigiKeyClient.Credentials = .init(clientID: "client id", clientSecret: "s&cret=")) -> HorizontalDigiKeyClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DigiKeyStubProtocol.self]
        configuration.httpAdditionalHeaders = [DigiKeyStubProtocol.serverHeader: id]
        return HorizontalDigiKeyClient(credentials: credentials, site: "US", session: URLSession(configuration: configuration), requestSpacing: .zero)
    }
}

private final class DigiKeyStubProtocol: URLProtocol {
    static let serverHeader = "X-Stub-Server"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: DigiKeyStubServer] = [:]

    static func register(_ server: DigiKeyStubServer) {
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
