import Combine
import Foundation

extension HorizontalSecretStore {
    /// The user's Arrow API key, in the keychain. The login Arrow issues
    /// with it is no secret, and is kept with the settings.
    static let arrowAPIKey = HorizontalSecretStore.keychain(
        service: "com.twarge.app.horizontal.arrow",
        account: "api-key",
        label: "Horizontal Arrow API key",
        noun: "API key"
    )
}

/// The Parts pane's Arrow Stock column: each part's stock, asked of
/// Arrow's Pricing & Availability API with the user's own login and key,
/// for the rows on screen.
///
/// Arrow's terms allow what the API sends to be kept two days at most, and
/// its own guidance says not to keep it at all, so this goes by the
/// stricter, as Mouser's monitor does: an answer is held in memory while it
/// is fresh (half an hour) for the column to show, never written anywhere,
/// and dropped when Arrow is turned off or the login or key changes. Only a
/// part some row is showing is asked about, and only once rows have stayed
/// up for a moment, so scrolling past a list asks nothing; a menu's Check
/// Arrow Stock asks at once.
///
/// A refused login or key stops the lookups until one changes, and a
/// refusal for now stops them for a while. Settings' switch turns all of it
/// off: no lookups, no requests, no Arrow column or menu items. Off until
/// turned on: Arrow issues a login and key only on request.
@MainActor
final class HorizontalArrowStockMonitor: ObservableObject {
    static let shared = HorizontalArrowStockMonitor()

    static let enabledKey = "arrow.enabled"
    static let loginKey = "arrow.login"
    /// How long lookups wait after Arrow turns one away without saying for
    /// how long.
    static let refusalBackoff: TimeInterval = 10 * 60
    /// How long an answer is held, in memory only, before a part shown again
    /// is asked about again.
    static let holdFor: TimeInterval = 30 * 60
    /// How long a request that failed waits before it is tried again.
    static let retryFailuresAfter: TimeInterval = 10 * 60
    /// How long a row has to stay up before its part is asked about.
    static let defaultGatherDelay: Duration = .milliseconds(400)

    struct Record: Equatable {
        var answer: HorizontalArrowAnswer
        var checkedAt: Date
    }

    struct Failure: Equatable {
        var message: String
        var at: Date
    }

    enum Verification: Equatable {
        case checking
        case accepted
        case refused(String)
    }

    /// What the column shows for a part.
    enum CellState: Equatable {
        /// Turned off in Settings.
        case off
        case noMPN
        case notSetUp
        /// Set up, and not asked about yet.
        case pending
        case checking
        case answer(HorizontalArrowAnswer, checkedAt: Date, isRefreshing: Bool)
        case failed(String)
        /// Nothing known, and lookups stopped for `problem`.
        case unavailable(String)
    }

    @Published private(set) var records: [String: Record] = [:]
    @Published private(set) var failures: [String: Failure] = [:]
    @Published private(set) var checking: Set<String> = []
    /// Why lookups have stopped: the key refused, a call limit.
    @Published private(set) var problem: String?
    @Published private(set) var hasAPIKey: Bool
    /// What Arrow made of the key when Settings last asked.
    @Published private(set) var verification: Verification?
    /// The login Arrow issued with the key.
    @Published private(set) var login: String
    /// Settings' switch for everything Arrow: off, nothing is asked,
    /// nothing shows, and what was held is forgotten. Off by default; kept
    /// between launches.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            forget()
            if isEnabled {
                askAboutShownParts()
            }
        }
    }

    private enum Block {
        case key
        case until(Date)
    }

    private let defaults: UserDefaults
    private let secrets: HorizontalSecretStore
    private let makeClient: (HorizontalArrowCredentials) -> HorizontalArrowClient
    private let gatherDelay: Duration
    private let now: () -> Date
    private var apiKey: String?
    private var client: HorizontalArrowClient?
    private var block: Block?
    private var generation = 0
    /// The parts rows are showing, each with how many rows show it.
    private var shown: [String: (query: HorizontalPartQuery, rows: Int)] = [:]
    /// The parts waiting to be asked about, in the order they came.
    private var queue: [HorizontalPartQuery] = []
    private var queued: Set<String> = []
    /// Asked for from a menu: sent whether or not a row shows them.
    private var forced: Set<String> = []
    private var pump: Task<Void, Never>?
    private var unblock: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        secrets: HorizontalSecretStore = .arrowAPIKey,
        gatherDelay: Duration = HorizontalArrowStockMonitor.defaultGatherDelay,
        now: @escaping () -> Date = Date.init,
        makeClient: @escaping (HorizontalArrowCredentials) -> HorizontalArrowClient = { HorizontalArrowClient(credentials: $0) }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.gatherDelay = gatherDelay
        self.now = now
        self.makeClient = makeClient
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        login = defaults.string(forKey: Self.loginKey) ?? ""
        hasAPIKey = secrets.exists()
    }

    var isConfigured: Bool { hasAPIKey && !login.isEmpty }

    func state(for part: HorizontalPoolPart) -> CellState {
        state(for: HorizontalPartQuery(part: part))
    }

    func state(for query: HorizontalPartQuery) -> CellState {
        guard isEnabled else { return .off }
        guard !query.mpn.isEmpty else { return .noMPN }
        guard isConfigured else { return .notSetUp }
        let key = query.key
        if let record = records[key] {
            return .answer(record.answer, checkedAt: record.checkedAt, isRefreshing: checking.contains(key))
        }
        if checking.contains(key) { return .checking }
        if let failure = failures[key] { return .failed(failure.message) }
        if let problem { return .unavailable(problem) }
        return .pending
    }

    /// The product page Arrow answered with for the part, while its answer
    /// is held.
    func productURL(for query: HorizontalPartQuery) -> URL? {
        guard isEnabled, let record = records[query.key], isFresh(record),
              case .stocked(let stock) = record.answer else { return nil }
        return stock.productURL
    }

    // MARK: Rows

    /// A row has come up showing the part: it is asked about once rows have
    /// stayed up for the gather delay, unless its answer is fresh.
    func show(_ query: HorizontalPartQuery) {
        guard !query.mpn.isEmpty else { return }
        let key = query.key
        shown[key] = (query, (shown[key]?.rows ?? 0) + 1)
        enqueue(query, force: false)
    }

    /// The row showing the part has gone; a part no row shows any more is
    /// not asked about.
    func hide(_ query: HorizontalPartQuery) {
        let key = query.key
        guard let entry = shown[key] else { return }
        if entry.rows > 1 {
            shown[key] = (entry.query, entry.rows - 1)
        } else {
            shown[key] = nil
        }
    }

    func show(_ part: HorizontalPoolPart) { show(HorizontalPartQuery(part: part)) }
    func hide(_ part: HorizontalPoolPart) { hide(HorizontalPartQuery(part: part)) }

    /// Asks Arrow about the parts now, shown or not: a menu's Check Arrow
    /// Stock. Without force, a fresh answer stands.
    func lookUp(_ queries: [HorizontalPartQuery], force: Bool = true) {
        for query in queries {
            enqueue(query, force: force)
        }
    }

    // MARK: Lookups

    private func enqueue(_ query: HorizontalPartQuery, force: Bool) {
        guard isEnabled, isConfigured, !query.mpn.isEmpty, isBlockLifted() else { return }
        let key = query.key
        guard !checking.contains(key), force || needsAsking(key) else { return }
        if force {
            forced.insert(key)
        }
        if queued.insert(key).inserted {
            queue.append(query)
        }
        startPump()
    }

    private func needsAsking(_ key: String) -> Bool {
        if let record = records[key], isFresh(record) { return false }
        if let failure = failures[key], now().timeIntervalSince(failure.at) < Self.retryFailuresAfter { return false }
        return true
    }

    private func isFresh(_ record: Record) -> Bool {
        now().timeIntervalSince(record.checkedAt) < Self.holdFor
    }

    private func isBlockLifted() -> Bool {
        switch block {
        case .key:
            return false
        case .until(let date):
            guard date <= now() else { return false }
            block = nil
            problem = nil
            return true
        case nil:
            return true
        }
    }

    private func startPump() {
        guard pump == nil else { return }
        let generation = generation
        pump = Task { [weak self, gatherDelay] in
            if gatherDelay > .zero {
                try? await Task.sleep(for: gatherDelay)
            }
            await self?.drainQueue(generation: generation)
        }
    }

    /// Asks about what is queued, a part at a time, until nothing is left.
    private func drainQueue(generation: Int) async {
        defer {
            if self.generation == generation {
                pump = nil
            }
        }
        dropStaleRecords()
        while self.generation == generation, !Task.isCancelled {
            guard let query = nextQuery() else { return }
            guard let client = currentClient() else {
                clearQueue()
                return
            }
            let key = query.key
            checking.insert(key)
            let result: Result<HorizontalArrowAnswer, Error>
            do {
                result = .success(try await client.answer(for: query))
            } catch {
                result = .failure(error)
            }
            guard self.generation == generation else { return }
            checking.remove(key)
            if !record(query, result) {
                clearQueue()
                return
            }
        }
    }

    /// The next queued part still wanted: shown by a row, or asked for from
    /// a menu.
    private func nextQuery() -> HorizontalPartQuery? {
        while !queue.isEmpty {
            let query = queue.removeFirst()
            let key = query.key
            queued.remove(key)
            let isForced = forced.remove(key) != nil
            if isForced || (shown[key] != nil && needsAsking(key)), !checking.contains(key) {
                return query
            }
        }
        return nil
    }

    /// Takes a part's answer in; false when the lookups have to stop.
    private func record(_ query: HorizontalPartQuery, _ result: Result<HorizontalArrowAnswer, Error>) -> Bool {
        let at = now()
        let key = query.key
        switch result {
        case .success(let answer):
            records[key] = Record(answer: answer, checkedAt: at)
            failures[key] = nil
            return true
        case .failure(let error):
            if error is CancellationError {
                return false
            }
            let failure = error as? HorizontalArrowClient.Failure ?? .transport("Arrow couldn't be reached.")
            switch failure {
            case .unauthorized(let message):
                block = .key
                problem = message
                verification = .refused(message)
                return false
            case .rateLimited(let retryAfter):
                let until = at.addingTimeInterval(retryAfter ?? Self.refusalBackoff)
                block = .until(until)
                problem = failure.message
                scheduleUnblock(at: until)
                return false
            default:
                failures[key] = Failure(message: failure.message, at: at)
                return true
            }
        }
    }

    /// Once a refusal for now lifts, the parts still shown are asked about.
    private func scheduleUnblock(at date: Date) {
        unblock?.cancel()
        let generation = generation
        let wait = max(date.timeIntervalSince(now()), 0)
        unblock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.unblock = nil
            if case .until = self.block {
                self.block = nil
                self.problem = nil
            }
            self.askAboutShownParts()
        }
    }

    private func askAboutShownParts() {
        for entry in shown.values.sorted(by: { $0.query.key < $1.query.key }) {
            enqueue(entry.query, force: false)
        }
    }

    /// Answers past their time that no row shows any more are let go.
    private func dropStaleRecords() {
        let stale = records.filter { !isFresh($0.value) && shown[$0.key] == nil }.map(\.key)
        for key in stale {
            records[key] = nil
        }
    }

    private func clearQueue() {
        queue.removeAll()
        queued.removeAll()
        forced.removeAll()
    }

    /// Ends every lookup and forgets every answer: nothing Arrow sent
    /// outlasts the switch or the key it came with.
    private func forget() {
        generation += 1
        pump?.cancel()
        pump = nil
        unblock?.cancel()
        unblock = nil
        clearQueue()
        checking.removeAll()
        records.removeAll()
        failures.removeAll()
        block = nil
        problem = nil
    }

    // MARK: Login and key

    /// Keeps the login with the settings and the key in the keychain, and
    /// starts over with them. An empty key leaves the one already saved, so
    /// the login can be corrected without typing the key again.
    func saveCredentials(login: String, apiKey key: String) throws {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty, !key.isEmpty || hasAPIKey else { return }
        if !key.isEmpty {
            try secrets.write(key)
            apiKey = key
            hasAPIKey = true
        }
        defaults.set(login, forKey: Self.loginKey)
        self.login = login
        keyChanged()
    }

    func removeCredentials() throws {
        try secrets.write(nil)
        apiKey = nil
        hasAPIKey = false
        defaults.removeObject(forKey: Self.loginKey)
        login = ""
        keyChanged()
    }

    /// Searches once, for Settings to say whether Arrow takes the login and
    /// key.
    func verifyCredentials() async {
        guard isEnabled, isConfigured, let client = currentClient() else {
            verification = nil
            return
        }
        let generation = generation
        verification = .checking
        let outcome: Verification
        do {
            try await client.verifyCredentials()
            outcome = .accepted
        } catch let failure as HorizontalArrowClient.Failure {
            outcome = .refused(failure.message)
        } catch {
            outcome = .refused("Arrow couldn't be reached.")
        }
        guard generation == self.generation else { return }
        verification = outcome
        if outcome == .accepted, case .key = block {
            block = nil
            problem = nil
            askAboutShownParts()
        }
    }

    private func keyChanged() {
        forget()
        client = nil
        verification = nil
        askAboutShownParts()
    }

    private func currentClient() -> HorizontalArrowClient? {
        guard isConfigured else { return nil }
        if let client { return client }
        if apiKey == nil {
            apiKey = secrets.read()
        }
        guard let apiKey, !apiKey.isEmpty else {
            hasAPIKey = false
            return nil
        }
        let client = makeClient(HorizontalArrowCredentials(login: login, apiKey: apiKey))
        self.client = client
        return client
    }
}

extension HorizontalArrowStockMonitor.CellState {
    /// The cell's text.
    var title: String {
        switch self {
        case .off: ""
        case .noMPN: "-"
        case .notSetUp: "Not set up"
        case .pending: ""
        case .checking: "Checking"
        case .answer(.stocked(let stock), _, _): stock.inStock.formatted()
        case .answer(.notCarried, _, _): "Not carried"
        case .failed: "Error"
        case .unavailable: "Unavailable"
        }
    }

    /// Out of stock, or failed: drawn in orange.
    var isWarning: Bool {
        switch self {
        case .answer(.stocked(let stock), _, _): stock.inStock == 0
        case .failed, .unavailable: true
        default: false
        }
    }

    var isNumeric: Bool {
        if case .answer(.stocked, _, _) = self { return true }
        return false
    }

    /// Arrow has answered for the part, stocked or not.
    var hasAnswer: Bool {
        if case .answer = self { return true }
        return false
    }

    var productURL: URL? {
        if case .answer(.stocked(let stock), _, _) = self { return stock.productURL }
        return nil
    }

    /// The cell's tooltip: what Arrow has, what the other sites it answers
    /// for have, and when it was asked, with the data credited to Arrow.
    func help(for part: HorizontalPoolPart) -> String {
        switch self {
        case .off:
            return "Arrow is turned off in Settings."
        case .noMPN:
            return "This part has no MPN to look up on Arrow."
        case .notSetUp:
            return "Add your Arrow login and API key in Settings to see Arrow's stock."
        case .pending:
            return ""
        case .checking:
            return "Asking Arrow about \(part.mpn)…"
        case .failed(let message), .unavailable(let message):
            return message
        case .answer(let answer, let checkedAt, let isRefreshing):
            var lines: [String]
            switch answer {
            case .notCarried:
                lines = ["Arrow lists nothing under the MPN \(part.mpn)."]
            case .stocked(let stock):
                lines = ["\(stock.manufacturer) \(stock.manufacturerPartNumber) at Arrow",
                         "\(stock.inStock.formatted()) in stock"]
                for site in stock.elsewhere.prefix(3) {
                    lines.append("\(site.name): \(site.quantity.formatted())")
                }
                if stock.matchedByMPNOnly, !part.manufacturer.isEmpty {
                    lines.append("Matched by MPN alone: Arrow has no \(part.mpn) from \(part.manufacturer).")
                }
                if stock.productURL != nil {
                    lines.append("Click to open the part on Arrow.")
                }
            }
            lines.append("Stock data from Arrow Electronics.")
            lines.append(isRefreshing
                ? "Checking again…"
                : "Checked \(checkedAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
            return lines.joined(separator: "\n")
        }
    }
}
