import Combine
import Foundation

extension HorizontalSecretStore {
    /// The user's Mouser Search API key, in the keychain.
    static let mouserAPIKey = HorizontalSecretStore.keychain(
        service: "com.twarge.app.horizontal.mouser",
        account: "search-api-key",
        label: "Horizontal Mouser Search API key",
        noun: "API key"
    )
}

/// The Parts pane's Mouser Stock column: each part's stock, asked of
/// Mouser's Search API with the user's own key, for the rows on screen.
///
/// Mouser's API terms forbid caching, pre-fetching or storing what the API
/// sends, so this keeps far less than DigiKey's monitor does: an answer is
/// held in memory while it is fresh (half an hour) for the column to show,
/// never written anywhere, and dropped when Mouser is turned off or the key
/// changes. Only a part some row is showing is asked about, and only once
/// rows have stayed up for a moment, so scrolling past a list asks nothing;
/// a menu's Check Mouser Stock asks at once.
///
/// A refused key stops the lookups until the key changes, and a call limit
/// stops them until Mouser says to come back. Settings' switch turns all of
/// it off: no lookups, no requests, no Mouser column or menu items.
@MainActor
final class HorizontalMouserStockMonitor: ObservableObject {
    static let shared = HorizontalMouserStockMonitor()

    static let enabledKey = "mouser.enabled"
    /// How long an answer is held, in memory only, before a part shown again
    /// is asked about again.
    static let holdFor: TimeInterval = 30 * 60
    /// How long a request that failed waits before it is tried again.
    static let retryFailuresAfter: TimeInterval = 10 * 60
    /// How long a row has to stay up before its part is asked about.
    static let defaultGatherDelay: Duration = .milliseconds(400)

    struct Record: Equatable {
        var answer: HorizontalMouserAnswer
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
        case answer(HorizontalMouserAnswer, checkedAt: Date, isRefreshing: Bool)
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
    /// What Mouser made of the key when Settings last asked.
    @Published private(set) var verification: Verification?
    /// Settings' switch for everything Mouser: off, nothing is asked,
    /// nothing shows, and what was held is forgotten. On by default; kept
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
    private let makeClient: (String) -> HorizontalMouserClient
    private let gatherDelay: Duration
    private let now: () -> Date
    private var apiKey: String?
    private var client: HorizontalMouserClient?
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
        secrets: HorizontalSecretStore = .mouserAPIKey,
        gatherDelay: Duration = HorizontalMouserStockMonitor.defaultGatherDelay,
        now: @escaping () -> Date = Date.init,
        makeClient: @escaping (String) -> HorizontalMouserClient = { HorizontalMouserClient(apiKey: $0) }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.gatherDelay = gatherDelay
        self.now = now
        self.makeClient = makeClient
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        hasAPIKey = secrets.exists()
    }

    var isConfigured: Bool { hasAPIKey }

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

    /// The product page Mouser answered with for the part, while its answer
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

    /// Asks Mouser about the parts now, shown or not: a menu's Check Mouser
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

    /// Asks about what is queued, a batch at a time, until nothing is left.
    private func drainQueue(generation: Int) async {
        defer {
            if self.generation == generation {
                pump = nil
            }
        }
        dropStaleRecords()
        while self.generation == generation, !Task.isCancelled {
            let batch = nextBatch()
            guard !batch.isEmpty else { return }
            guard let client = currentClient() else {
                clearQueue()
                return
            }
            let keys = batch.map(\.key)
            checking.formUnion(keys)
            let result: Result<[String: HorizontalMouserAnswer], Error>
            do {
                result = .success(try await client.answers(for: batch))
            } catch {
                result = .failure(error)
            }
            guard self.generation == generation else { return }
            checking.subtract(keys)
            if !record(batch, result) {
                clearQueue()
                return
            }
        }
    }

    /// Up to a batch of the queued parts still wanted: shown by a row, or
    /// asked for from a menu. One the search can't carry fails at once.
    private func nextBatch() -> [HorizontalPartQuery] {
        var batch: [HorizontalPartQuery] = []
        while !queue.isEmpty, batch.count < HorizontalMouserClient.batchSize {
            let query = queue.removeFirst()
            let key = query.key
            queued.remove(key)
            let isForced = forced.remove(key) != nil
            guard isForced || (shown[key] != nil && needsAsking(key)), !checking.contains(key) else { continue }
            guard HorizontalMouserClient.canSearch(query.mpn) else {
                failures[key] = Failure(message: HorizontalMouserClient.unsearchableMessage(query.mpn), at: now())
                continue
            }
            batch.append(query)
        }
        return batch
    }

    /// Takes a batch's answers in; false when the lookups have to stop.
    private func record(_ batch: [HorizontalPartQuery], _ result: Result<[String: HorizontalMouserAnswer], Error>) -> Bool {
        let at = now()
        switch result {
        case .success(let answers):
            for query in batch {
                let key = query.key
                records[key] = Record(answer: answers[key] ?? .notCarried, checkedAt: at)
                failures[key] = nil
            }
            return true
        case .failure(let error):
            if error is CancellationError {
                return false
            }
            let failure = error as? HorizontalMouserClient.Failure ?? .transport(error.localizedDescription)
            switch failure {
            case .unauthorized(let message):
                block = .key
                problem = message
                verification = .refused(message)
                return false
            case .rateLimited(let retryAfter, _):
                let until = at.addingTimeInterval(retryAfter ?? 60)
                block = .until(until)
                problem = failure.message
                scheduleUnblock(at: until)
                return false
            default:
                for query in batch {
                    failures[query.key] = Failure(message: failure.message, at: at)
                }
                return true
            }
        }
    }

    /// Once a call limit lifts, the parts still shown are asked about.
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

    /// Ends every lookup and forgets every answer: nothing Mouser sent
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

    // MARK: Key

    /// Keeps the key in the keychain and starts over with it.
    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try secrets.write(trimmed)
        apiKey = trimmed
        hasAPIKey = true
        keyChanged()
    }

    func removeAPIKey() throws {
        try secrets.write(nil)
        apiKey = nil
        hasAPIKey = false
        keyChanged()
    }

    /// Searches once, for Settings to say whether Mouser takes the key.
    func verifyAPIKey() async {
        guard isEnabled, isConfigured, let client = currentClient() else {
            verification = nil
            return
        }
        let generation = generation
        verification = .checking
        let outcome: Verification
        do {
            try await client.verifyKey()
            outcome = .accepted
        } catch let failure as HorizontalMouserClient.Failure {
            outcome = .refused(failure.message)
        } catch {
            outcome = .refused(error.localizedDescription)
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

    private func currentClient() -> HorizontalMouserClient? {
        guard isConfigured else { return nil }
        if let client { return client }
        if apiKey == nil {
            apiKey = secrets.read()
        }
        guard let apiKey, !apiKey.isEmpty else {
            hasAPIKey = false
            return nil
        }
        let client = makeClient(apiKey)
        self.client = client
        return client
    }
}

extension HorizontalMouserStockMonitor.CellState {
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

    /// Out of stock, winding down, or failed: drawn in orange.
    var isWarning: Bool {
        switch self {
        case .answer(.stocked(let stock), _, _): stock.inStock == 0 || stock.isWindingDown
        case .failed, .unavailable: true
        default: false
        }
    }

    var isNumeric: Bool {
        if case .answer(.stocked, _, _) = self { return true }
        return false
    }

    /// Mouser has answered for the part, stocked or not.
    var hasAnswer: Bool {
        if case .answer = self { return true }
        return false
    }

    var productURL: URL? {
        if case .answer(.stocked(let stock), _, _) = self { return stock.productURL }
        return nil
    }

    /// The cell's tooltip: what Mouser has, on order and at the factory, its
    /// part number, and when it was asked, with the data credited to Mouser.
    func help(for part: HorizontalPoolPart) -> String {
        switch self {
        case .off:
            return "Mouser is turned off in Settings."
        case .noMPN:
            return "This part has no MPN to look up on Mouser."
        case .notSetUp:
            return "Add your Mouser Search API key in Settings to see Mouser's stock."
        case .pending:
            return ""
        case .checking:
            return "Asking Mouser about \(part.mpn)…"
        case .failed(let message), .unavailable(let message):
            return message
        case .answer(let answer, let checkedAt, let isRefreshing):
            var lines: [String]
            switch answer {
            case .notCarried:
                lines = ["Mouser sells nothing under the MPN \(part.mpn)."]
            case .stocked(let stock):
                let number = stock.mouserPartNumber.isEmpty ? "" : " (\(stock.mouserPartNumber))"
                lines = ["\(stock.manufacturer) \(stock.manufacturerPartNumber) at Mouser\(number)",
                         "\(stock.inStock.formatted()) in stock"]
                if stock.factoryStock > 0 {
                    lines.append("Factory stock: \(stock.factoryStock.formatted())")
                }
                for order in stock.onOrder.prefix(3) {
                    let date = Self.day(order.date)
                    lines.append("On order: \(order.quantity.formatted())\(date.isEmpty ? "" : ", expected \(date)")")
                }
                let status = [
                    stock.isDiscontinued ? "Discontinued at Mouser" : nil,
                    stock.lifecycleStatus
                ].compactMap { $0 }
                if !status.isEmpty {
                    lines.append(status.joined(separator: ", "))
                }
                if let replacement = stock.suggestedReplacement {
                    lines.append("Suggested replacement: \(replacement)")
                }
                if stock.inStock == 0, let leadTime = stock.leadTime {
                    lines.append("Lead time: \(leadTime)")
                }
                if stock.matchedByMPNOnly, !part.manufacturer.isEmpty {
                    lines.append("Matched by MPN alone: Mouser has no \(part.mpn) from \(part.manufacturer).")
                }
                if stock.productURL != nil {
                    lines.append("Click to open the part on Mouser.")
                }
            }
            lines.append("Stock data from Mouser Electronics.")
            lines.append(isRefreshing
                ? "Checking again…"
                : "Checked \(checkedAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
            return lines.joined(separator: "\n")
        }
    }

    /// The day of one of Mouser's dates ("2026-11-04T00:00:00").
    private static func day(_ date: String) -> String {
        let trimmed = date.trimmingCharacters(in: .whitespaces)
        if let t = trimmed.firstIndex(of: "T"), trimmed.distance(from: trimmed.startIndex, to: t) == 10 {
            return String(trimmed[..<t])
        }
        return trimmed
    }
}
