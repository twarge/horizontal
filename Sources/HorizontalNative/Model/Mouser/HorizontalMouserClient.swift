import Foundation

/// What Mouser has of one part, as its Search API reports it.
struct HorizontalMouserStock: Equatable, Sendable {
    var mouserPartNumber: String
    var manufacturer: String
    var manufacturerPartNumber: String
    /// What Mouser has on its own shelves.
    var inStock: Int
    /// What the manufacturer holds that Mouser can order, where it says.
    var factoryStock = 0
    /// Mouser's orders still to come in, each with the date it gives.
    var onOrder: [OnOrder] = []
    /// The manufacturer's lead time, as Mouser words it ("6 Weeks").
    var leadTime: String?
    /// Mouser's word for where the part is in its life: New Product, End
    /// of Life, Obsolete and the like; nil for an ordinary active part.
    var lifecycleStatus: String?
    var isDiscontinued = false
    var suggestedReplacement: String?
    var productURL: URL?
    /// No product's manufacturer matched the part's, so its MPN alone chose
    /// this one.
    var matchedByMPNOnly = false

    struct OnOrder: Equatable, Sendable {
        var quantity: Int
        var date: String
    }

    /// Discontinued, or at the end of its life: what stock there is won't
    /// be replenished.
    var isWindingDown: Bool {
        guard !isDiscontinued else { return true }
        let status = lifecycleStatus?.lowercased() ?? ""
        return ["end of life", "obsolete", "not recommended", "nrnd", "last time buy"].contains { status.contains($0) }
    }
}

/// Mouser's answer for one MPN: what it has, or that it sells nothing under
/// that MPN.
enum HorizontalMouserAnswer: Equatable, Sendable {
    case stocked(HorizontalMouserStock)
    case notCarried
}

/// Mouser's Search API, with the user's own Search API key: Mouser issues a
/// key to whoever enrolls and forbids passing it on, so each user brings
/// theirs. The key rides in the query string of every request. One request
/// asks about up to ten part numbers, and requests start no closer together
/// than `requestSpacing`; Mouser assigns each key its call limits and
/// doesn't publish them, so the spacing stays well inside a minute's.
actor HorizontalMouserClient {
    enum Failure: Error, Equatable {
        /// Mouser refused the key.
        case unauthorized(String)
        /// Over a call limit; Mouser's own words where it gave any.
        case rateLimited(retryAfter: TimeInterval?, message: String)
        /// Mouser answered the search with errors of its own.
        case refused(String)
        case http(status: Int, detail: String)
        case transport(String)
        case malformedResponse
        /// The MPN can't be put to Mouser's part number search at all.
        case unsearchable(String)

        var message: String {
            switch self {
            case .unauthorized(let message), .refused(let message), .unsearchable(let message):
                return message
            case .rateLimited(let retryAfter, let message):
                let said = message.isEmpty ? "Mouser's call limit was reached." : "Mouser's call limit was reached (\(message))."
                guard let retryAfter, retryAfter > 0 else {
                    return "\(said) Try again later."
                }
                let duration = Duration.seconds(retryAfter.rounded(.up))
                return "\(said) Try again in \(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)))."
            case .http(let status, let detail):
                return detail.isEmpty ? "Mouser answered with HTTP \(status)." : "Mouser answered with HTTP \(status): \(detail)"
            case .transport(let message):
                return message
            case .malformedResponse:
                return "Mouser's answer couldn't be read."
            }
        }
    }

    static let baseURL = URL(string: "https://api.mouser.com")!
    /// The most part numbers one search takes, separated by `|`.
    static let batchSize = 10
    /// The lengths of part number the search takes.
    static let partNumberLengths = 3...40
    /// 30 requests a minute.
    static let defaultRequestSpacing: Duration = .seconds(2)
    /// How long a refusal for the day holds lookups back, where Mouser says
    /// no more than that.
    static let dailyLimitBackoff: TimeInterval = 60 * 60

    let apiKey: String
    private let session: URLSession
    private let requestSpacing: Duration
    private var nextRequestAt = ContinuousClock.now

    init(
        apiKey: String,
        session: URLSession = .shared,
        requestSpacing: Duration = HorizontalMouserClient.defaultRequestSpacing
    ) {
        self.apiKey = apiKey
        self.session = session
        self.requestSpacing = requestSpacing
    }

    /// Whether the part number search can carry the MPN: three to forty
    /// characters, and no `|`, which separates the part numbers of a batch.
    static func canSearch(_ mpn: String) -> Bool {
        partNumberLengths.contains(mpn.count) && !mpn.contains("|")
    }

    static func unsearchableMessage(_ mpn: String) -> String {
        mpn.contains("|")
            ? "Mouser's part number search can't take an MPN with a | in it."
            : "Mouser's part number search takes part numbers of 3 to 40 characters."
    }

    /// Searches once, so Settings can say whether Mouser takes the key. It
    /// costs one request, as any search does.
    func verifyKey() async throws {
        _ = try await search(["LM358DR"])
    }

    /// What Mouser has of each part, keyed by `HorizontalPartQuery.key`: up
    /// to ten parts in one request. A batch whose results Mouser cut short
    /// asks again, one by one, about the parts it found nothing for.
    func answers(for queries: [HorizontalPartQuery]) async throws -> [String: HorizontalMouserAnswer] {
        var unique: [String: HorizontalPartQuery] = [:]
        for query in queries where !query.mpn.isEmpty {
            unique[query.key] = query
        }
        guard !unique.isEmpty else { return [:] }
        if let unsearchable = unique.values.first(where: { !Self.canSearch($0.mpn) }) {
            throw Failure.unsearchable(Self.unsearchableMessage(unsearchable.mpn))
        }
        var mpns: [String] = []
        var seenMPNs = Set<String>()
        for query in unique.values.sorted(by: { $0.key < $1.key })
        where seenMPNs.insert(HorizontalPartQuery.normalizedMPN(query.mpn)).inserted {
            mpns.append(query.mpn)
        }
        guard mpns.count <= Self.batchSize else {
            throw Failure.unsearchable("Mouser's part number search takes at most \(Self.batchSize) part numbers at once.")
        }
        let results = try await search(mpns)
        var answers: [String: HorizontalMouserAnswer] = [:]
        for (key, query) in unique {
            answers[key] = Self.answer(for: results.parts, mpn: query.mpn, manufacturer: query.manufacturer)
        }
        if results.isTruncated, mpns.count > 1 {
            for (key, query) in unique.sorted(by: { $0.key < $1.key }) where answers[key] == .notCarried {
                try Task.checkCancellation()
                let single = try await search([query.mpn])
                answers[key] = Self.answer(for: single.parts, mpn: query.mpn, manufacturer: query.manufacturer)
            }
        }
        return answers
    }

    // MARK: Requests

    struct Results: Sendable {
        var parts: [Part]
        /// Mouser found more than it sent.
        var isTruncated: Bool
    }

    private func search(_ mpns: [String]) async throws -> Results {
        try await waitForRequestSlot()
        let (data, response) = try await send(searchRequest(mpns: mpns))
        let root = try? JSONDecoder().decode(SearchResponseRoot.self, from: data)
        if let errors = root?.Errors, !errors.isEmpty {
            throw Self.failure(for: errors, response: response)
        }
        switch response.statusCode {
        case 200:
            guard let root else { throw Failure.malformedResponse }
            let parts = root.SearchResults?.Parts ?? []
            return Results(parts: parts, isTruncated: (root.SearchResults?.NumberOfResult ?? 0) > parts.count)
        case 401, 403:
            throw Failure.unauthorized("Mouser refused the API key (HTTP \(response.statusCode)).")
        case 429:
            throw Failure.rateLimited(retryAfter: Self.retryAfter(response), message: "")
        default:
            throw Failure.http(status: response.statusCode, detail: Self.text(of: data))
        }
    }

    /// The part number search, Exact: the MPNs joined by `|`, the key in
    /// the query string.
    func searchRequest(mpns: [String]) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("api/v1/search/partnumber"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "apiKey", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "SearchByPartRequest": [
                "mouserPartNumber": mpns.joined(separator: "|"),
                "partSearchOptions": "Exact"
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
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
    /// address, which carries the key.
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
            throw Failure.transport(Self.describe(error))
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformedResponse
        }
        return (data, http)
    }

    private static func describe(_ error: URLError) -> String {
        let description = URLError(error.code).localizedDescription
        return description.isEmpty ? "Mouser couldn't be reached." : description
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func text(of data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What Mouser's errors come to: a call limit, a key it doesn't take
    /// (its errors name the API Key property), or a refusal of the search.
    static func failure(for errors: [ErrorEntity], response: HTTPURLResponse?) -> Failure {
        let messages = errors.compactMap { $0.Message?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let said = messages.joined(separator: " ")
        func words(_ error: ErrorEntity) -> String {
            [error.Code, error.ResourceKey, error.Message].compactMap { $0 }.joined(separator: " ").lowercased()
        }
        if let limit = errors.first(where: { error in
            let text = words(error)
            return ["toomanyrequests", "too many requests", "calls per", "exceeded", "rate limit"].contains { text.contains($0) }
        }) {
            let daily = words(limit).contains("day") || words(limit).contains("daily")
            let wait = response.flatMap(Self.retryAfter) ?? (daily ? dailyLimitBackoff : 60)
            return .rateLimited(retryAfter: wait, message: limit.Message ?? "")
        }
        if errors.contains(where: { ($0.PropertyName ?? "").lowercased().contains("key") })
            || response.map({ [401, 403].contains($0.statusCode) }) == true {
            return .unauthorized(said.isEmpty ? "Mouser didn't accept the API key." : "Mouser didn't accept the API key (\(said)).")
        }
        return .refused(said.isEmpty ? "Mouser refused the search." : "Mouser refused the search: \(said)")
    }

    // MARK: Matching

    /// The part that answers among those Mouser found: one whose MPN is the
    /// part's and that Mouser sells (a listing without a Mouser part number
    /// is one it doesn't), from the part's manufacturer where one is, with
    /// the most in stock where several are.
    static func answer(for parts: [Part], mpn: String, manufacturer: String) -> HorizontalMouserAnswer {
        let wanted = HorizontalPartQuery.normalizedMPN(mpn)
        let exact = parts.filter { HorizontalPartQuery.normalizedMPN($0.manufacturerPartNumber) == wanted && $0.isSold }
        guard !exact.isEmpty else { return .notCarried }
        let sameMaker = exact.filter { part in
            part.manufacturers.contains { HorizontalPartQuery.manufacturersMatch($0, manufacturer) }
        }
        let candidates = sameMaker.isEmpty ? exact : sameMaker
        var stock = candidates.max { $0.stock.inStock < $1.stock.inStock }!.stock
        stock.matchedByMPNOnly = sameMaker.isEmpty
        return .stocked(stock)
    }

    // MARK: Wire format

    /// A MouserPart. Mouser sends its counts as strings, "38268" or
    /// "38268 In Stock", and its flags as "true" or "false".
    struct Part: Decodable, Equatable, Sendable {
        var manufacturerPartNumber: String
        /// Mouser's name for the maker, then the actual maker's where Mouser
        /// gives another (a brand it files under its owner).
        var manufacturers: [String]
        var stock: HorizontalMouserStock

        var isSold: Bool {
            let number = stock.mouserPartNumber.trimmingCharacters(in: .whitespaces)
            return !number.isEmpty && number.uppercased() != "N/A"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func string(_ key: String) -> String? {
                if let text = (try? c.decodeIfPresent(String.self, forKey: Key(key))) ?? nil { return text }
                if let number = (try? c.decodeIfPresent(Int.self, forKey: Key(key))) ?? nil { return String(number) }
                if let flag = (try? c.decodeIfPresent(Bool.self, forKey: Key(key))) ?? nil { return String(flag) }
                return nil
            }
            func nonEmpty(_ key: String) -> String? {
                string(key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            manufacturerPartNumber = string("ManufacturerPartNumber") ?? ""
            var names: [String] = []
            for name in [nonEmpty("Manufacturer"), nonEmpty("ActualMfrName")].compactMap({ $0 }) where !names.contains(name) {
                names.append(name)
            }
            manufacturers = names
            let availability = string("Availability") ?? ""
            let inStock = Self.count(string("AvailabilityInStock"))
                ?? (availability.lowercased().contains("in stock") ? Self.count(availability) : nil)
                ?? 0
            let onOrder = (((try? c.decodeIfPresent([WireOnOrder].self, forKey: Key("AvailabilityOnOrder"))) ?? nil) ?? []).compactMap { order -> HorizontalMouserStock.OnOrder? in
                guard let quantity = order.Quantity, quantity > 0 else { return nil }
                return HorizontalMouserStock.OnOrder(quantity: quantity, date: order.Date ?? "")
            }
            stock = HorizontalMouserStock(
                mouserPartNumber: string("MouserPartNumber") ?? "",
                manufacturer: names.first ?? "",
                manufacturerPartNumber: manufacturerPartNumber,
                inStock: inStock,
                factoryStock: Self.count(string("FactoryStock")) ?? 0,
                onOrder: onOrder,
                leadTime: nonEmpty("LeadTime"),
                lifecycleStatus: nonEmpty("LifecycleStatus"),
                isDiscontinued: string("IsDiscontinued")?.lowercased() == "true",
                suggestedReplacement: nonEmpty("SuggestedReplacement"),
                productURL: nonEmpty("ProductDetailUrl").flatMap { URL(string: $0) }
            )
        }

        /// The number a count starts with, thousands separators and all.
        static func count(_ text: String?) -> Int? {
            guard let text else { return nil }
            let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "," || $0 == "." }
                .filter(\.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        private struct WireOnOrder: Decodable {
            var Quantity: Int?
            var Date: String?
        }
    }

    struct ErrorEntity: Decodable, Equatable, Sendable {
        var Code: String?
        var Message: String?
        var ResourceKey: String?
        var PropertyName: String?
    }

    private struct SearchResponseRoot: Decodable {
        var Errors: [ErrorEntity]?
        var SearchResults: SearchResults?
    }

    private struct SearchResults: Decodable {
        var NumberOfResult: Int?
        var Parts: [Part]?
    }
}
