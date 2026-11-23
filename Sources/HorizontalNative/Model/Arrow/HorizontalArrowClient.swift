import Foundation

/// What Arrow has of one part, as its Pricing & Availability API reports it.
struct HorizontalArrowStock: Equatable, Sendable {
    var manufacturer: String
    var manufacturerPartNumber: String
    /// What arrow.com itself has on hand, over every source it lists.
    var inStock: Int
    /// What the other sites Arrow answers for have (Verical, its
    /// marketplace), each by the name Arrow gives it.
    var elsewhere: [Site] = []
    var productURL: URL?
    /// No product's manufacturer matched the part's, so its MPN alone chose
    /// this one.
    var matchedByMPNOnly = false

    struct Site: Equatable, Sendable {
        var name: String
        var quantity: Int
    }
}

/// Arrow's answer for one MPN: what it has, or that it lists nothing under
/// that MPN.
enum HorizontalArrowAnswer: Equatable, Sendable {
    case stocked(HorizontalArrowStock)
    case notCarried
}

/// The login and API key Arrow issues together, to whoever it approves.
struct HorizontalArrowCredentials: Equatable, Sendable {
    var login: String
    var apiKey: String
}

/// Arrow's Pricing & Availability API (item service v4), with the user's own
/// login and API key: Arrow issues them on request and forbids sharing them
/// outside the company they were issued to, so each user brings theirs.
/// Both ride in the query string of every request.
///
/// One request asks about one part number, through the token search. The
/// list search takes many, but wants the caller's IP address in the request,
/// which an app on someone's desk has no honest way to give. Arrow publishes
/// no call limit; requests start no closer together than `requestSpacing`.
///
/// Arrow answers a refused login or key with HTTP 200 and a message in the
/// body, whose wordings its documentation doesn't list: `failure(for:)`
/// reads them by the words they are likely to use, and anything else is a
/// refusal of that one search.
actor HorizontalArrowClient {
    enum Failure: Error, Equatable {
        /// Arrow refused the login or the key.
        case unauthorized(String)
        case rateLimited(retryAfter: TimeInterval?)
        /// Arrow answered the search with an error of its own.
        case refused(String)
        case http(status: Int, detail: String)
        case transport(String)
        case malformedResponse

        var message: String {
            switch self {
            case .unauthorized(let message), .refused(let message):
                return message
            case .rateLimited(let retryAfter):
                guard let retryAfter, retryAfter > 0 else {
                    return "Arrow is turning requests away for now. Try again later."
                }
                let duration = Duration.seconds(retryAfter.rounded(.up))
                return "Arrow is turning requests away for now. Try again in \(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)))."
            case .http(let status, let detail):
                return detail.isEmpty ? "Arrow answered with HTTP \(status)." : "Arrow answered with HTTP \(status): \(detail)"
            case .transport(let message):
                return message
            case .malformedResponse:
                return "Arrow's answer couldn't be read."
            }
        }
    }

    static let baseURL = URL(string: "https://api.arrow.com")!
    /// The most parts the token search sends back, which is a prefix search:
    /// asked for all of them, so the part itself is among them.
    static let rows = 25
    static let defaultRequestSpacing: Duration = .seconds(1)

    let credentials: HorizontalArrowCredentials
    private let session: URLSession
    private let requestSpacing: Duration
    private var nextRequestAt = ContinuousClock.now

    init(
        credentials: HorizontalArrowCredentials,
        session: URLSession = .shared,
        requestSpacing: Duration = HorizontalArrowClient.defaultRequestSpacing
    ) {
        self.credentials = credentials
        self.session = session
        self.requestSpacing = requestSpacing
    }

    /// Searches once, so Settings can say whether Arrow takes the login and
    /// key.
    func verifyCredentials() async throws {
        _ = try await search("BAV99")
    }

    /// What Arrow has of the part.
    func answer(for query: HorizontalPartQuery) async throws -> HorizontalArrowAnswer {
        guard !query.mpn.isEmpty else { return .notCarried }
        let parts = try await search(query.mpn)
        return Self.answer(for: parts, mpn: query.mpn, manufacturer: query.manufacturer)
    }

    // MARK: Requests

    private func search(_ mpn: String) async throws -> [Part] {
        try await waitForRequestSlot()
        let (data, response) = try await send(searchRequest(mpn: mpn))
        switch response.statusCode {
        case 200:
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let result = root["itemserviceresult"] as? [String: Any] else {
                throw Failure.malformedResponse
            }
            return try Self.parts(in: result)
        case 401, 403:
            throw Failure.unauthorized("Arrow refused the login or API key (HTTP \(response.statusCode)).")
        case 429:
            throw Failure.rateLimited(retryAfter: Self.retryAfter(response))
        default:
            throw Failure.http(status: response.statusCode, detail: Self.text(of: data))
        }
    }

    /// The token search: the MPN, exactly or as a prefix, the login and key
    /// in the query string.
    func searchRequest(mpn: String) -> URLRequest {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("itemservice/v4/en/search/token"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = [
            ("login", credentials.login), ("apikey", credentials.apiKey), ("search_token", mpn), ("rows", String(Self.rows)),
        ].map { "\($0.0)=\(encoded($0.1))" }.joined(separator: "&")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func waitForRequestSlot() async throws {
        try Task.checkCancellation()
        let now = ContinuousClock.now
        let slot = max(now, nextRequestAt)
        nextRequestAt = slot + requestSpacing
        if slot > now {
            try await Task.sleep(until: slot, clock: .continuous)
        }
    }

    /// Sends a request. A transport error's description never names the
    /// address, which carries the login and key.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            let description = URLError(error.code).localizedDescription
            throw Failure.transport(description.isEmpty ? "Arrow couldn't be reached." : description)
        } catch {
            throw Failure.transport("Arrow couldn't be reached.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformedResponse
        }
        return (data, http)
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func text(of data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reading the answer

    /// One part Arrow lists: its numbers, and what each site has of it.
    struct Part: Equatable, Sendable {
        var manufacturerPartNumber: String
        var manufacturer: String
        var productURL: URL?
        /// Each site's name and what it has on hand, in Arrow's order.
        var sites: [HorizontalArrowStock.Site]
    }

    /// The parts in an `itemserviceresult`. Arrow says in its transaction
    /// area whether the search went through; one that found nothing is no
    /// failure, whichever way Arrow says it.
    static func parts(in result: [String: Any]) throws -> [Part] {
        let data = (result["data"] as? [[String: Any]]) ?? []
        let parts = data.flatMap { ($0["PartList"] as? [[String: Any]]) ?? [] }.compactMap(part)
        let response = ((result["transactionArea"] as? [[String: Any]])?.first?["response"] as? [String: Any]) ?? [:]
        if parts.isEmpty, (response["success"] as? Bool) == false {
            let message = (response["returnMsg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let failure = failure(for: message) {
                throw failure
            }
        }
        return parts
    }

    /// What Arrow's own error comes to: nil where it only says it found
    /// nothing, a refused login or key where it names one, and otherwise a
    /// refusal of the search in Arrow's words.
    static func failure(for message: String) -> Failure? {
        let text = message.lowercased()
        if text.isEmpty || ["no result", "no match", "not found", "no part", "no item", "no data"].contains(where: text.contains) {
            return nil
        }
        if ["login", "apikey", "api key", "api_key", "credential", "authoriz", "authentic", "permission", "access denied"]
            .contains(where: text.contains) {
            return .unauthorized("Arrow didn't accept the login and API key (\(message)).")
        }
        if ["limit", "too many", "throttl", "quota"].contains(where: text.contains) {
            return .rateLimited(retryAfter: nil)
        }
        return .refused("Arrow refused the search: \(message)")
    }

    private static func part(_ item: [String: Any]) -> Part? {
        guard let number = string(item["partNum"]), !number.isEmpty else { return nil }
        let maker = (item["manufacturer"] as? [String: Any]).flatMap { string($0["mfrName"]) } ?? ""
        let webSites = ((item["InvOrg"] as? [String: Any])?["webSites"] as? [[String: Any]]) ?? []
        var detail = resource(in: item, types: ["cloud_part_detail", "detail"])
        var sites = [HorizontalArrowStock.Site]()
        for site in webSites {
            var quantity = 0
            for source in (site["sources"] as? [[String: Any]]) ?? [] {
                for sourcePart in (source["sourceParts"] as? [[String: Any]]) ?? [] {
                    for availability in (sourcePart["Availability"] as? [[String: Any]]) ?? [] {
                        quantity += count(availability["fohQty"]) ?? 0
                    }
                    if detail == nil {
                        detail = resource(in: sourcePart, types: ["detail"])
                    }
                }
            }
            let name = string(site["name"]) ?? string(site["code"]) ?? ""
            sites.append(.init(name: name, quantity: quantity))
        }
        return Part(manufacturerPartNumber: number, manufacturer: maker, productURL: detail, sites: sites)
    }

    private static func resource(in item: [String: Any], types: [String]) -> URL? {
        let resources = (item["resources"] as? [[String: Any]]) ?? []
        for type in types {
            if let uri = resources.first(where: { string($0["type"]) == type }).flatMap({ string($0["uri"]) }),
               let url = URL(string: uri), url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A count, sent as a number or as a number in a string.
    private static func count(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return max(number.intValue, 0) }
        if let text = value as? String, let number = Double(text.trimmingCharacters(in: .whitespaces)) { return max(Int(number), 0) }
        return nil
    }

    /// Whether a site Arrow answers for is arrow.com itself.
    static func isArrowItself(_ site: HorizontalArrowStock.Site) -> Bool {
        site.name.lowercased().contains("arrow")
    }

    // MARK: Matching

    /// The part that answers among those Arrow found, which a prefix search
    /// fills with longer part numbers: one whose MPN is the part's, from the
    /// part's manufacturer where one is, with the most on hand where
    /// several are.
    static func answer(for parts: [Part], mpn: String, manufacturer: String) -> HorizontalArrowAnswer {
        let wanted = HorizontalPartQuery.normalizedMPN(mpn)
        let exact = parts.filter { HorizontalPartQuery.normalizedMPN($0.manufacturerPartNumber) == wanted }
        guard !exact.isEmpty else { return .notCarried }
        let sameMaker = exact.filter { HorizontalPartQuery.manufacturersMatch($0.manufacturer, manufacturer) }
        func stock(_ part: Part) -> HorizontalArrowStock {
            HorizontalArrowStock(
                manufacturer: part.manufacturer,
                manufacturerPartNumber: part.manufacturerPartNumber,
                inStock: part.sites.filter(isArrowItself).reduce(0) { $0 + $1.quantity },
                elsewhere: part.sites.filter { !isArrowItself($0) && $0.quantity > 0 },
                productURL: part.productURL,
                matchedByMPNOnly: sameMaker.isEmpty
            )
        }
        let candidates = (sameMaker.isEmpty ? exact : sameMaker).map(stock)
        func total(_ stock: HorizontalArrowStock) -> Int {
            stock.inStock + stock.elsewhere.reduce(0) { $0 + $1.quantity }
        }
        guard let best = candidates.max(by: { ($0.inStock, total($0)) < ($1.inStock, total($1)) }) else {
            return .notCarried
        }
        return .stocked(best)
    }
}
