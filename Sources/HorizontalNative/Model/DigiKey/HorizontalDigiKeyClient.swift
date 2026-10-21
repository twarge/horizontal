import Foundation

/// What DigiKey stocks of one part, as its Product Information API (v4)
/// reports it: the product that answered, and what it has under each of its
/// packagings.
struct HorizontalDigiKeyStock: Codable, Equatable, Sendable {
    /// The product's own count, which DigiKey can report as 0 while its
    /// packagings have stock; `selection(for:)` counts a packaging's.
    var quantityAvailable: Int
    var manufacturer: String
    var manufacturerProductNumber: String
    var productURL: URL?
    /// The DigiKey part numbers the product is sold under, one per
    /// packaging, with what each has.
    var variations: [Variation]
    var isDiscontinued = false
    var isObsolete = false
    var isEndOfLife = false
    /// Weeks to more stock from the manufacturer, as DigiKey words it.
    var manufacturerLeadWeeks: String?
    /// No product's manufacturer matched the part's, so its MPN alone chose
    /// this one.
    var matchedByMPNOnly = false

    struct Variation: Codable, Equatable, Sendable {
        var digiKeyProductNumber: String
        var packageType: String
        var quantityAvailable: Int
        var isMarketplace = false
    }

    /// Discontinued, obsolete or at its end of life: what stock there is
    /// won't be replenished.
    var isWindingDown: Bool {
        isDiscontinued || isObsolete || isEndOfLife
    }

    /// The packaging a count is taken from.
    struct Selection: Equatable {
        /// Nil when DigiKey listed no packagings, and the product's own count
        /// stands.
        var variation: Variation?
        var quantity: Int
        /// The part doesn't come in the packaging asked for, so the most
        /// stocked of the others stands in.
        var isFallback: Bool
    }

    /// What DigiKey has in `packaging`: the variation in it with the most
    /// stock, one DigiKey ships itself before a Marketplace seller's, and cut
    /// tape where two have the same (a Digi-Reel is cut from the same stock).
    /// A part that doesn't come in it counts its most stocked packaging
    /// instead.
    func selection(for packaging: HorizontalDigiKeyPackaging) -> Selection {
        let matching = packaging == .any ? variations : variations.filter(packaging.matches)
        if let variation = Self.mostStocked(matching) {
            return Selection(variation: variation, quantity: variation.quantityAvailable, isFallback: false)
        }
        if let variation = Self.mostStocked(variations) {
            return Selection(variation: variation, quantity: variation.quantityAvailable, isFallback: true)
        }
        return Selection(variation: nil, quantity: quantityAvailable, isFallback: false)
    }

    private static func mostStocked(_ variations: [Variation]) -> Variation? {
        func rank(_ variation: Variation) -> (Int, Int, Int) {
            (variation.isMarketplace ? 0 : 1, variation.quantityAvailable, HorizontalDigiKeyPackaging.cutTape.matches(variation) ? 1 : 0)
        }
        return variations.max { rank($0) < rank($1) }
    }
}

/// The packaging the DigiKey Stock column counts: DigiKey sells a part on cut
/// tape, full reels and its own Digi-Reels as separate part numbers, each
/// with its own stock.
enum HorizontalDigiKeyPackaging: String, CaseIterable, Identifiable, Sendable {
    /// Whichever packaging has the most: the default.
    case any
    case cutTape
    case tapeAndReel
    case digiReel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Most Stocked"
        case .cutTape: "Cut Tape"
        case .tapeAndReel: "Tape & Reel"
        case .digiReel: "Digi-Reel"
        }
    }

    /// Whether a variation is in this packaging: by DigiKey's name for it,
    /// else by the suffix its part numbers carry (CT-ND, TR-ND, DKR-ND).
    func matches(_ variation: HorizontalDigiKeyStock.Variation) -> Bool {
        let name = variation.packageType.lowercased()
        let number = variation.digiKeyProductNumber.uppercased()
        switch self {
        case .cutTape:
            return name.isEmpty ? number.hasSuffix("CT-ND") : name.contains("cut tape")
        case .tapeAndReel:
            return name.isEmpty ? number.hasSuffix("TR-ND") : name.contains("tape & reel") || name.contains("tape and reel")
        case .digiReel:
            return name.isEmpty ? number.hasSuffix("DKR-ND") : name.contains("digi-reel")
        case .any:
            return true
        }
    }
}

/// DigiKey's answer for one MPN: what it stocks, or that it sells nothing
/// under that MPN.
enum HorizontalDigiKeyAnswer: Codable, Equatable, Sendable {
    case stocked(HorizontalDigiKeyStock)
    case notCarried
}

/// DigiKey's Product Information API v4, signed in with OAuth 2's client
/// credentials grant (DigiKey's "2-legged" flow): the app's client ID and
/// secret buy a bearer token good for ten minutes, and each MPN then costs
/// one request against the app's quota (1,000 a day and 120 a minute on
/// DigiKey's free tier). Requests start no closer together than the minute
/// limit allows.
actor HorizontalDigiKeyClient {
    struct Credentials: Equatable, Sendable {
        var clientID: String
        var clientSecret: String
    }

    enum Failure: Error, Equatable {
        /// DigiKey refused the credentials or the app's access to the API.
        case unauthorized(String)
        /// Over a rate limit; DigiKey says when to come back where it can.
        case rateLimited(retryAfter: TimeInterval?)
        case http(status: Int, detail: String)
        case transport(String)
        case malformedResponse

        var message: String {
            switch self {
            case .unauthorized(let message):
                return message
            case .rateLimited(let retryAfter):
                guard let retryAfter, retryAfter > 0 else {
                    return "DigiKey's rate limit was reached. Try again later."
                }
                let duration = Duration.seconds(retryAfter.rounded(.up))
                return "DigiKey's rate limit was reached. Try again in \(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)))."
            case .http(let status, let detail):
                return detail.isEmpty ? "DigiKey answered with HTTP \(status)." : "DigiKey answered with HTTP \(status): \(detail)"
            case .transport(let message):
                return message
            case .malformedResponse:
                return "DigiKey's answer couldn't be read."
            }
        }
    }

    static let baseURL = URL(string: "https://api.digikey.com")!
    /// The sites the API takes for X-DIGIKEY-Locale-Site; a product's link
    /// and what may be sold differ between them.
    static let sites: Set<String> = [
        "AT", "AU", "BE", "BG", "BR", "CA", "CH", "CN", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HK", "HU",
        "IE", "IL", "IN", "IT", "JP", "KR", "LT", "LU", "LV", "MX", "MY", "NL", "NO", "NZ", "PH", "PL", "PT", "RO",
        "SE", "SG", "SI", "SK", "TH", "TW", "UK", "US", "ZA"
    ]
    /// How many products one MPN looks at. The pricing search takes partial
    /// part numbers, so an MPN that is the start of others brings them too.
    static let resultLimit = 10
    /// 120 requests a minute.
    static let defaultRequestSpacing: Duration = .milliseconds(500)

    let credentials: Credentials
    let site: String
    private let session: URLSession
    private let requestSpacing: Duration
    private var token: (value: String, expires: Date)?
    private var tokenTask: Task<(value: String, expires: Date), Error>?
    private var nextRequestAt = ContinuousClock.now

    init(
        credentials: Credentials,
        site: String = HorizontalDigiKeyClient.defaultSite(),
        session: URLSession = .shared,
        requestSpacing: Duration = HorizontalDigiKeyClient.defaultRequestSpacing
    ) {
        self.credentials = credentials
        self.site = site
        self.session = session
        self.requestSpacing = requestSpacing
    }

    /// The DigiKey site for the user's region, else the US one. DigiKey
    /// calls Great Britain UK.
    static func defaultSite(locale: Locale = .current) -> String {
        let region = locale.region?.identifier.uppercased() ?? "US"
        let site = region == "GB" ? "UK" : region
        return sites.contains(site) ? site : "US"
    }

    /// Asks for a token, so the settings can say whether DigiKey takes the
    /// credentials without spending a product request.
    func verifyCredentials() async throws {
        _ = try await bearerToken(refresh: true)
    }

    /// What DigiKey has of `mpn`, the product from `manufacturer` where
    /// several makers use the MPN.
    func answer(mpn: String, manufacturer: String) async throws -> HorizontalDigiKeyAnswer {
        let trimmed = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notCarried }
        let (data, status) = try await authorized(pricingRequest(mpn: trimmed))
        // A part number with a slash, a hash or the like in it can trip up
        // the path it rides in; the keyword search takes it in a body.
        let keywordFallback = Self.needsKeywordSearch(trimmed)
        switch status {
        case 200:
            guard let response = try? JSONDecoder().decode(PricingResponse.self, from: data) else {
                throw Failure.malformedResponse
            }
            let answer = Self.answer(for: response.ProductPricings ?? [], mpn: trimmed, manufacturer: manufacturer)
            if answer == .notCarried, keywordFallback {
                return try await keywordAnswer(mpn: trimmed, manufacturer: manufacturer)
            }
            return answer
        case 400 where keywordFallback, 404 where keywordFallback:
            return try await keywordAnswer(mpn: trimmed, manufacturer: manufacturer)
        case 404:
            return .notCarried
        default:
            throw Self.failure(status: status, data: data)
        }
    }

    private func keywordAnswer(mpn: String, manufacturer: String) async throws -> HorizontalDigiKeyAnswer {
        let (data, status) = try await authorized(keywordRequest(mpn: mpn))
        switch status {
        case 200:
            guard let response = try? JSONDecoder().decode(KeywordResponse.self, from: data) else {
                throw Failure.malformedResponse
            }
            return Self.answer(for: (response.ExactMatches ?? []) + (response.Products ?? []), mpn: mpn, manufacturer: manufacturer)
        case 404:
            return .notCarried
        default:
            throw Self.failure(status: status, data: data)
        }
    }

    // MARK: Requests

    /// Sends a request with a bearer token, after the one before it by the
    /// request spacing. A token DigiKey no longer takes is replaced once.
    private func authorized(_ request: URLRequest) async throws -> (Data, Int) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let token = try await bearerToken(refresh: attempt > 0)
            var signed = request
            signed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            try await waitForRequestSlot()
            let (data, response) = try await send(signed)
            if response.statusCode == 401, attempt == 0 {
                attempt += 1
                continue
            }
            if response.statusCode == 429 {
                throw Failure.rateLimited(retryAfter: Self.retryAfter(response))
            }
            return (data, response.statusCode)
        }
    }

    private func waitForRequestSlot() async throws {
        let now = ContinuousClock.now
        let slot = max(now, nextRequestAt)
        nextRequestAt = slot + requestSpacing
        if slot > now {
            try await Task.sleep(until: slot, clock: .continuous)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformedResponse
        }
        return (data, http)
    }

    /// The token in hand, or a new one; requests that want one at once
    /// share a single sign-in.
    private func bearerToken(refresh: Bool) async throws -> String {
        if refresh {
            token = nil
        }
        if let token, token.expires > Date() {
            return token.value
        }
        if let tokenTask {
            return try await tokenTask.value.value
        }
        let request = tokenRequest()
        let session = session
        let task = Task { () throws -> (value: String, expires: Date) in
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw Failure.transport(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw Failure.malformedResponse
            }
            switch http.statusCode {
            case 200:
                guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data), !body.access_token.isEmpty else {
                    throw Failure.malformedResponse
                }
                // A margin, so a token isn't sent in its last seconds.
                let lifetime = max(Double(body.expires_in ?? 600) - 30, 30)
                return (body.access_token, Date().addingTimeInterval(lifetime))
            case 400, 401, 403:
                throw Failure.unauthorized(Self.refusedCredentials(Self.detail(of: data)))
            case 429:
                throw Failure.rateLimited(retryAfter: Self.retryAfter(http))
            default:
                throw Self.failure(status: http.statusCode, data: data)
            }
        }
        tokenTask = task
        defer { tokenTask = nil }
        let fresh = try await task.value
        token = fresh
        return fresh.value
    }

    private func tokenRequest() -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let fields = [
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
            ("grant_type", "client_credentials")
        ]
        request.httpBody = Data(fields.map { "\($0)=\(Self.formEncoded($1))" }.joined(separator: "&").utf8)
        return request
    }

    func pricingRequest(mpn: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = Self.baseURL.scheme
        components.host = Self.baseURL.host
        components.percentEncodedPath = "/products/v4/search/\(Self.pathSegment(mpn))/pricing"
        components.queryItems = [URLQueryItem(name: "limit", value: String(Self.resultLimit))]
        return productRequest(url: components.url!)
    }

    func keywordRequest(mpn: String) -> URLRequest {
        var request = productRequest(url: Self.baseURL.appendingPathComponent("products/v4/search/keyword"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["Keywords": String(mpn.prefix(250)), "Limit": Self.resultLimit, "Offset": 0]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func productRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(credentials.clientID, forHTTPHeaderField: "X-DIGIKEY-Client-Id")
        request.setValue(site, forHTTPHeaderField: "X-DIGIKEY-Locale-Site")
        request.setValue("en", forHTTPHeaderField: "X-DIGIKEY-Locale-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The MPN as one path segment: everything but RFC 3986's unreserved
    /// characters escaped, a slash included.
    static func pathSegment(_ mpn: String) -> String {
        mpn.addingPercentEncoding(withAllowedCharacters: unreserved) ?? mpn
    }

    static func needsKeywordSearch(_ mpn: String) -> Bool {
        pathSegment(mpn) != mpn
    }

    private static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// What DigiKey says went wrong, in either of the shapes its errors
    /// take: the products API's problem details, or the sign-in's older
    /// ErrorMessage.
    private static func detail(of data: Data) -> String {
        let problem = try? JSONDecoder().decode(ProblemDetails.self, from: data)
        return [problem?.detail, problem?.ErrorMessage, problem?.title].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    private static func refusedCredentials(_ detail: String) -> String {
        detail.isEmpty
            ? "DigiKey didn't accept the client ID and secret."
            : "DigiKey didn't accept the client ID and secret (\(detail))."
    }

    private static func failure(status: Int, data: Data) -> Failure {
        let detail = Self.detail(of: data)
        switch status {
        case 401:
            return .unauthorized(refusedCredentials(detail))
        case 403:
            return .unauthorized(detail.isEmpty
                ? "DigiKey refused the request. Check that the app is subscribed to the Product Information V4 API."
                : "DigiKey refused the request: \(detail)")
        default:
            return .http(status: status, detail: detail)
        }
    }

    // MARK: Matching

    /// The product that answers for a part among those DigiKey found: one
    /// whose MPN is the part's, from the part's manufacturer where one is,
    /// with the most stock in any packaging where several are.
    static func answer(for products: [Product], mpn: String, manufacturer: String) -> HorizontalDigiKeyAnswer {
        let wanted = normalizedMPN(mpn)
        let exact = products.filter { normalizedMPN($0.manufacturerProductNumber) == wanted }
        guard !exact.isEmpty else { return .notCarried }
        let sameMaker = exact.filter { manufacturersMatch($0.manufacturer, manufacturer) }
        let candidates = sameMaker.isEmpty ? exact : sameMaker
        let best = candidates.max { $0.mostStocked < $1.mostStocked }!
        var stock = best.stock
        stock.matchedByMPNOnly = sameMaker.isEmpty
        return .stocked(stock)
    }

    static func normalizedMPN(_ mpn: String) -> String {
        mpn.uppercased().filter { !$0.isWhitespace }
    }

    static func normalizedManufacturer(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// One name inside the other once case, spaces and punctuation are
    /// gone: Murata and Murata Electronics, Maxim Integrated and DigiKey's
    /// Analog Devices Inc./Maxim Integrated. Names shorter than three
    /// letters (TI, ST) match nothing; the MPN chooses for them.
    static func manufacturersMatch(_ a: String, _ b: String) -> Bool {
        let x = normalizedManufacturer(a)
        let y = normalizedManufacturer(b)
        guard x.count >= 3, y.count >= 3 else { return false }
        return x.contains(y) || y.contains(x)
    }

    // MARK: Wire format

    /// A product from either search: the pricing search's ProductPricing or
    /// the keyword search's Product, which name a few fields differently.
    struct Product: Decodable, Equatable, Sendable {
        var manufacturerProductNumber: String
        var manufacturer: String
        var quantityAvailable: Int
        var productURL: URL?
        var isDiscontinued: Bool
        var isObsolete: Bool
        var isEndOfLife: Bool
        var manufacturerLeadWeeks: String?
        var variations: [HorizontalDigiKeyStock.Variation]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func string(_ key: String) -> String? { (try? c.decodeIfPresent(String.self, forKey: Key(key))) ?? nil }
            func int(_ key: String) -> Int? { (try? c.decodeIfPresent(Int.self, forKey: Key(key))) ?? nil }
            func bool(_ key: String) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: Key(key))) ?? nil }
            manufacturerProductNumber = string("ManufacturerProductNumber") ?? ""
            manufacturer = ((try? c.decodeIfPresent(Named.self, forKey: Key("Manufacturer"))) ?? nil)?.Name ?? ""
            quantityAvailable = int("QuantityAvailable") ?? 0
            productURL = string("ProductUrl").flatMap { URL(string: $0) }
            let status = ((try? c.decodeIfPresent(Status.self, forKey: Key("ProductStatus"))) ?? nil)?.Status ?? ""
            isDiscontinued = bool("IsDiscontinued") ?? bool("Discontinued") ?? false
            isObsolete = bool("IsObsolete") ?? (status.caseInsensitiveCompare("Obsolete") == .orderedSame)
            isEndOfLife = bool("IsEndOfLife") ?? bool("EndOfLife") ?? false
            manufacturerLeadWeeks = string("ManufacturerLeadWeeks").flatMap { $0.isEmpty ? nil : $0 }
            variations = (((try? c.decodeIfPresent([WireVariation].self, forKey: Key("ProductVariations"))) ?? nil) ?? []).map {
                HorizontalDigiKeyStock.Variation(
                    digiKeyProductNumber: $0.DigiKeyProductNumber ?? "",
                    packageType: $0.PackageType?.Name ?? "",
                    quantityAvailable: $0.QuantityAvailableforPackageType ?? 0,
                    isMarketplace: $0.MarketPlace ?? false
                )
            }
        }

        var mostStocked: Int {
            max(quantityAvailable, variations.map(\.quantityAvailable).max() ?? 0)
        }

        var stock: HorizontalDigiKeyStock {
            HorizontalDigiKeyStock(
                quantityAvailable: quantityAvailable,
                manufacturer: manufacturer,
                manufacturerProductNumber: manufacturerProductNumber,
                productURL: productURL,
                variations: variations,
                isDiscontinued: isDiscontinued,
                isObsolete: isObsolete,
                isEndOfLife: isEndOfLife,
                manufacturerLeadWeeks: manufacturerLeadWeeks
            )
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        private struct Named: Decodable { var Name: String? }
        private struct Status: Decodable { var Status: String? }
        private struct WireVariation: Decodable {
            var DigiKeyProductNumber: String?
            var PackageType: Named?
            var QuantityAvailableforPackageType: Int?
            var MarketPlace: Bool?
        }
    }

    private struct PricingResponse: Decodable {
        var ProductPricings: [Product]?
    }

    private struct KeywordResponse: Decodable {
        var ExactMatches: [Product]?
        var Products: [Product]?
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int?
    }

    private struct ProblemDetails: Decodable {
        var title: String?
        var detail: String?
        var ErrorMessage: String?
    }
}
