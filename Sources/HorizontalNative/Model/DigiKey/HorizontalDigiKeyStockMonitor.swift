import Combine
import Foundation

extension HorizontalSecretStore {
    /// The DigiKey API client secret, in the keychain.
    static let digiKeyClientSecret = HorizontalSecretStore.keychain(
        service: "com.twarge.app.horizontal.digikey",
        account: "client-secret",
        label: "Horizontal DigiKey API client secret",
        noun: "client secret"
    )
}

/// The Parts pane's DigiKey Stock column: each part's stock, asked of
/// DigiKey's Product Information API once and kept for half a day, here and
/// on disk, so reopening a project costs no requests. One monitor serves
/// every document, since stock is no document's own; the client ID and
/// secret it signs in with are the app's, set in Settings.
///
/// A refused sign-in stops the lookups until the credentials change, and a
/// rate limit stops them until DigiKey says to come back. Settings' switch
/// turns all of it off: no lookups, no requests, and no DigiKey column or
/// menu items anywhere.
@MainActor
final class HorizontalDigiKeyStockMonitor: ObservableObject {
    static let shared = HorizontalDigiKeyStockMonitor()

    static let clientIDKey = "digikey.clientID"
    static let enabledKey = "digikey.enabled"
    static let packagingKey = "digikey.packaging"
    /// How long an answer stands before a part is asked about again.
    static let freshFor: TimeInterval = 12 * 60 * 60
    /// How long a request that failed waits before it is tried again.
    static let retryFailuresAfter: TimeInterval = 10 * 60
    /// Answers older than this are dropped from the disk cache.
    static let keepRecordsFor: TimeInterval = 30 * 24 * 60 * 60
    static let concurrentRequests = 4

    struct Record: Codable, Equatable, Sendable {
        var answer: HorizontalDigiKeyAnswer
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
        case answer(HorizontalDigiKeyAnswer, checkedAt: Date, isRefreshing: Bool, packaging: HorizontalDigiKeyPackaging)
        case failed(String)
        /// Nothing known, and lookups stopped for `problem`.
        case unavailable(String)
    }

    @Published private(set) var records: [String: Record] = [:]
    @Published private(set) var failures: [String: Failure] = [:]
    @Published private(set) var checking: Set<String> = []
    /// Why lookups have stopped: the credentials refused, a rate limit.
    @Published private(set) var problem: String?
    @Published private(set) var clientID: String
    @Published private(set) var hasClientSecret: Bool
    /// What DigiKey made of the credentials when Settings last asked.
    @Published private(set) var verification: Verification?
    /// Bumped whenever the credentials change, so a view looks up again.
    @Published private(set) var credentialsRevision = 0
    /// Settings' switch for everything DigiKey: off, nothing is asked and
    /// nothing shows. On by default; kept between launches. Turning it off
    /// stops the lookups in flight and keeps the answers already in.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                stopLookups()
            }
        }
    }
    /// Which packaging's stock the column shows. Every packaging comes in one
    /// answer, so changing it asks DigiKey nothing.
    @Published var packaging: HorizontalDigiKeyPackaging {
        didSet { defaults.set(packaging.rawValue, forKey: Self.packagingKey) }
    }

    private enum Block {
        case credentials
        case until(Date)
    }

    private let defaults: UserDefaults
    private let secrets: HorizontalSecretStore
    private let cacheURL: URL?
    private let makeClient: (HorizontalDigiKeyClient.Credentials) -> HorizontalDigiKeyClient
    private var clientSecret: String?
    private var client: HorizontalDigiKeyClient?
    private var block: Block?
    private var generation = 0
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0
    private var saveTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        secrets: HorizontalSecretStore = .digiKeyClientSecret,
        cacheURL: URL? = HorizontalDigiKeyStockMonitor.defaultCacheURL(),
        makeClient: @escaping (HorizontalDigiKeyClient.Credentials) -> HorizontalDigiKeyClient = { HorizontalDigiKeyClient(credentials: $0) }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.cacheURL = cacheURL
        self.makeClient = makeClient
        clientID = defaults.string(forKey: Self.clientIDKey) ?? ""
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        packaging = defaults.string(forKey: Self.packagingKey).flatMap(HorizontalDigiKeyPackaging.init(rawValue:)) ?? .any
        hasClientSecret = secrets.exists()
        records = Self.loadRecords(from: cacheURL)
    }

    nonisolated static func defaultCacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Horizontal", isDirectory: true)
            .appendingPathComponent("digikey-stock.json")
    }

    var isConfigured: Bool {
        !clientID.isEmpty && hasClientSecret
    }

    func state(for part: HorizontalPoolPart) -> CellState {
        state(for: HorizontalPartQuery(part: part))
    }

    func state(for query: HorizontalPartQuery) -> CellState {
        guard isEnabled else { return .off }
        guard !query.mpn.isEmpty else { return .noMPN }
        guard isConfigured else { return .notSetUp }
        let key = query.key
        if let record = records[key] {
            return .answer(record.answer, checkedAt: record.checkedAt, isRefreshing: checking.contains(key), packaging: packaging)
        }
        if checking.contains(key) { return .checking }
        if let failure = failures[key] { return .failed(failure.message) }
        if let problem { return .unavailable(problem) }
        return .pending
    }

    /// The product page DigiKey answered with for the part, while DigiKey is
    /// on: from an answer of any age, and with the credentials since removed,
    /// since a page outlasts its stock count.
    func productURL(for query: HorizontalPartQuery) -> URL? {
        guard isEnabled, case .stocked(let stock)? = records[query.key]?.answer else { return nil }
        return stock.productURL
    }

    // MARK: Lookups

    /// Asks DigiKey about the parts it has no fresh answer for, or about
    /// every one when forced. Parts already being asked about are left be.
    func lookUp(_ parts: [HorizontalPoolPart], force: Bool = false) {
        lookUp(parts.map(HorizontalPartQuery.init(part:)), force: force)
    }

    func lookUp(_ queries: [HorizontalPartQuery], force: Bool = false) {
        guard isEnabled, isConfigured, isBlockLifted() else { return }
        let now = Date()
        var batch: [String: HorizontalPartQuery] = [:]
        for query in queries where !query.mpn.isEmpty {
            let key = query.key
            guard batch[key] == nil, !checking.contains(key) else { continue }
            if !force {
                if let record = records[key], now.timeIntervalSince(record.checkedAt) < Self.freshFor { continue }
                if let failure = failures[key], now.timeIntervalSince(failure.at) < Self.retryFailuresAfter { continue }
            }
            batch[key] = query
        }
        // The secret is read only when there is something to ask.
        guard !batch.isEmpty, let client = currentClient() else { return }
        run(batch.sorted { $0.key < $1.key }, client: client)
    }

    private func isBlockLifted() -> Bool {
        switch block {
        case .credentials:
            return false
        case .until(let date):
            guard date <= Date() else { return false }
            block = nil
            problem = nil
            return true
        case nil:
            return true
        }
    }

    private func run(_ work: [(key: String, value: HorizontalPartQuery)], client: HorizontalDigiKeyClient) {
        checking.formUnion(work.map(\.key))
        let generation = generation
        let taskID = nextTaskID
        nextTaskID += 1
        tasks[taskID] = Task { [weak self] in
            await withTaskGroup(of: (String, Result<HorizontalDigiKeyAnswer, Error>).self) { group in
                var nextIndex = 0
                var stopped = false
                func enqueue() {
                    guard nextIndex < work.count else { return }
                    let (key, query) = work[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            return (key, .success(try await client.answer(mpn: query.mpn, manufacturer: query.manufacturer)))
                        } catch {
                            return (key, .failure(error))
                        }
                    }
                }
                for _ in 0..<Self.concurrentRequests {
                    enqueue()
                }
                while let finished = await group.next() {
                    let (key, result) = finished
                    guard let self, self.generation == generation else {
                        group.cancelAll()
                        return
                    }
                    // Every answer is taken in, even after a stop; nothing
                    // new is sent once one has come.
                    if !self.record(key, result) {
                        stopped = true
                        group.cancelAll()
                    }
                    if !stopped {
                        enqueue()
                    }
                }
            }
            guard let self, self.generation == generation else { return }
            self.checking.subtract(work.map(\.key))
            self.tasks[taskID] = nil
            self.scheduleSave()
        }
    }

    /// Takes one answer in; false when the lookups have to stop.
    private func record(_ key: String, _ result: Result<HorizontalDigiKeyAnswer, Error>) -> Bool {
        checking.remove(key)
        switch result {
        case .success(let answer):
            records[key] = Record(answer: answer, checkedAt: Date())
            failures[key] = nil
            return true
        case .failure(let error):
            if error is CancellationError {
                return true
            }
            let failure = error as? HorizontalDigiKeyClient.Failure ?? .transport(error.localizedDescription)
            switch failure {
            case .unauthorized(let message):
                block = .credentials
                problem = message
                verification = .refused(message)
                return false
            case .rateLimited(let retryAfter):
                block = .until(Date().addingTimeInterval(retryAfter ?? 60))
                problem = failure.message
                return false
            default:
                failures[key] = Failure(message: failure.message, at: Date())
                return true
            }
        }
    }

    // MARK: Credentials

    /// Keeps the client ID, and the secret where one is given (nil keeps the
    /// one stored), and starts over with them.
    func saveCredentials(clientID: String, clientSecret: String?) throws {
        if let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            try secrets.write(secret)
            self.clientSecret = secret
            hasClientSecret = true
        }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(id, forKey: Self.clientIDKey)
        self.clientID = id
        credentialsChanged()
    }

    func removeCredentials() throws {
        try secrets.write(nil)
        clientSecret = nil
        hasClientSecret = false
        defaults.removeObject(forKey: Self.clientIDKey)
        clientID = ""
        credentialsChanged()
    }

    /// Signs in once, for Settings to say whether DigiKey takes the
    /// credentials.
    func verifyCredentials() async {
        guard isEnabled, isConfigured, let client = currentClient() else {
            verification = nil
            return
        }
        let revision = credentialsRevision
        verification = .checking
        let outcome: Verification
        do {
            try await client.verifyCredentials()
            outcome = .accepted
        } catch let failure as HorizontalDigiKeyClient.Failure {
            outcome = .refused(failure.message)
        } catch {
            outcome = .refused(error.localizedDescription)
        }
        guard revision == credentialsRevision else { return }
        verification = outcome
        if outcome == .accepted, case .credentials = block {
            block = nil
            problem = nil
        }
    }

    /// Ends every lookup in flight; their answers are dropped.
    private func stopLookups() {
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        checking.removeAll()
    }

    private func credentialsChanged() {
        stopLookups()
        failures.removeAll()
        client = nil
        block = nil
        problem = nil
        verification = nil
        credentialsRevision += 1
    }

    private func currentClient() -> HorizontalDigiKeyClient? {
        guard isConfigured else { return nil }
        if let client { return client }
        if clientSecret == nil {
            clientSecret = secrets.read()
        }
        guard let clientSecret, !clientSecret.isEmpty else {
            hasClientSecret = false
            return nil
        }
        let client = makeClient(HorizontalDigiKeyClient.Credentials(clientID: clientID, clientSecret: clientSecret))
        self.client = client
        return client
    }

    // MARK: Disk cache

    private struct CacheFile: Codable {
        var version: Int
        var records: [String: Record]
    }

    private static let cacheVersion = 1

    private static func loadRecords(from url: URL?) -> [String: Record] {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == cacheVersion else {
            return [:]
        }
        let oldest = Date().addingTimeInterval(-keepRecordsFor)
        return file.records.filter { $0.value.checkedAt > oldest }
    }

    /// Writes the answers out a moment after a batch, off the main thread.
    private func scheduleSave() {
        guard let cacheURL else { return }
        saveTask?.cancel()
        let file = CacheFile(version: Self.cacheVersion, records: records)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(file) else { return }
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: [.atomic])
        }
    }
}

extension HorizontalDigiKeyStockMonitor.CellState {
    /// The packaging counted, for a part DigiKey stocks.
    var selection: HorizontalDigiKeyStock.Selection? {
        if case .answer(.stocked(let stock), _, _, let packaging) = self { return stock.selection(for: packaging) }
        return nil
    }

    /// The cell's text.
    var title: String {
        switch self {
        case .off: ""
        case .noMPN: "-"
        case .notSetUp: "Not set up"
        case .pending: ""
        case .checking: "Checking"
        case .answer(.stocked, _, _, _): selection?.quantity.formatted() ?? ""
        case .answer(.notCarried, _, _, _): "Not carried"
        case .failed: "Error"
        case .unavailable: "Unavailable"
        }
    }

    /// Out of stock, winding down, or failed: drawn in orange.
    var isWarning: Bool {
        switch self {
        case .answer(.stocked(let stock), _, _, _): selection?.quantity == 0 || stock.isWindingDown
        case .failed, .unavailable: true
        default: false
        }
    }

    var isNumeric: Bool {
        if case .answer(.stocked, _, _, _) = self { return true }
        return false
    }

    var productURL: URL? {
        if case .answer(.stocked(let stock), _, _, _) = self { return stock.productURL }
        return nil
    }

    /// The cell's tooltip: the packaging counted, what DigiKey has under each
    /// of its part numbers, and when it was asked.
    func help(for part: HorizontalPoolPart) -> String {
        switch self {
        case .off:
            return "DigiKey is turned off in Settings."
        case .noMPN:
            return "This part has no MPN to look up on DigiKey."
        case .notSetUp:
            return "Add a DigiKey API client ID and secret in Settings to see DigiKey's stock."
        case .pending:
            return ""
        case .checking:
            return "Asking DigiKey about \(part.mpn)…"
        case .failed(let message), .unavailable(let message):
            return message
        case .answer(let answer, let checkedAt, let isRefreshing, let packaging):
            var lines: [String]
            switch answer {
            case .notCarried:
                lines = ["DigiKey sells nothing under the MPN \(part.mpn)."]
            case .stocked(let stock):
                let selection = stock.selection(for: packaging)
                lines = ["\(stock.manufacturer) \(stock.manufacturerProductNumber) at DigiKey"]
                if let variation = selection.variation {
                    let counted = "\(variation.packageType.isEmpty ? variation.digiKeyProductNumber : variation.packageType): \(selection.quantity.formatted())"
                    lines.append(selection.isFallback
                        ? "Not sold as \(packaging.title); showing \(counted)"
                        : "Showing \(counted)")
                } else {
                    lines.append("\(selection.quantity.formatted()) in stock")
                }
                for variation in stock.variations where !variation.digiKeyProductNumber.isEmpty {
                    let package = variation.packageType.isEmpty ? "" : " (\(variation.packageType))"
                    let marketplace = variation.isMarketplace ? ", Marketplace" : ""
                    lines.append("\(variation.digiKeyProductNumber)\(package)\(marketplace): \(variation.quantityAvailable.formatted())")
                }
                let status = [
                    stock.isDiscontinued ? "Discontinued at DigiKey" : nil,
                    stock.isObsolete ? "Obsolete" : nil,
                    stock.isEndOfLife ? "End of life" : nil
                ].compactMap { $0 }
                if !status.isEmpty {
                    lines.append(status.joined(separator: ", "))
                }
                if selection.quantity == 0, let weeks = stock.manufacturerLeadWeeks {
                    lines.append("Manufacturer lead time: \(weeks.allSatisfy(\.isNumber) ? "\(weeks) weeks" : weeks)")
                }
                if stock.matchedByMPNOnly, !part.manufacturer.isEmpty {
                    lines.append("Matched by MPN alone: DigiKey has no \(part.mpn) from \(part.manufacturer).")
                }
                if stock.productURL != nil {
                    lines.append("Click to open the part on DigiKey.")
                }
            }
            lines.append(isRefreshing
                ? "Checking again…"
                : "Checked \(checkedAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
            return lines.joined(separator: "\n")
        }
    }
}
