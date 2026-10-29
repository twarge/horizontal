import Foundation
#if canImport(Network) && os(macOS)
import Network
#endif

/// The app's live channel: the same JSON-RPC dispatch, served over a loopback
/// TCP socket while at least one document is open. One request per line,
/// one response per line, each request carrying `"auth": <token>`.
///
/// The port is ephemeral; `~/Library/Application Support/Horizontal/live.json`
/// (inside the sandbox container when sandboxed) tells clients the port and
/// the token. The file is 0600 and the listener binds to 127.0.0.1 only.
@MainActor
enum HorizontalLiveServer {
    static let enabledDefaultsKey = "HorizontalLiveServerEnabled"

    /// Off until the user turns it on in Settings: the channel hands an
    /// automation client the documents on screen, so it opts in rather than
    /// out. Also the one place the default lives.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? false
    }

    /// Starts or stops the listener after the preference changes, so the
    /// toggle takes effect without closing and reopening a document.
    static func enabledDidChange() {
        documentsDidChange(count: HorizontalDispatchSession.shared.liveDocumentCount)
    }

    static func documentsDidChange(count: Int) {
        #if canImport(Network) && os(macOS)
        if count > 0, isEnabled() {
            HorizontalLiveListener.shared.start()
        } else {
            HorizontalLiveListener.shared.stop()
        }
        #endif
    }

    /// The loopback endpoint this process is serving, or nil when it is not.
    /// Published in the holder record beside each open project, because the
    /// discovery file below sits in the app's sandbox container and macOS
    /// refuses another process access to it.
    static func endpoint() -> [String: String]? {
        guard let port, let token else {
            return nil
        }
        return ["host": "127.0.0.1", "port": String(port), "token": token]
    }

    /// Tells every open document's holder record whether there is a channel to
    /// reach, so a client that just read the project can find it.
    static func endpointDidChange() {
        HorizontalDispatchSession.shared.refreshHolders(endpoint: endpoint())
    }

    static var discoveryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Horizontal", isDirectory: true).appendingPathComponent("live.json")
    }

    #if canImport(Network) && os(macOS)
    static var port: UInt16? { HorizontalLiveListener.shared.port }
    static var token: String? { HorizontalLiveListener.shared.token }
    #else
    static var port: UInt16? { nil }
    static var token: String? { nil }
    #endif

    /// Handles one request line from any transport: checks the token, then
    /// runs the dispatcher on the main actor with the live entries synced.
    static func handle(line: String, expectedToken: String) -> String {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              var request = object as? JSONDictionary else {
            return HorizontalDispatch.serialize(
                HorizontalDispatch.errorResponse(id: nil, code: .parseError, message: "Request is not a JSON object."),
                pretty: false
            )
        }
        guard let auth = request["auth"] as? String, auth == expectedToken else {
            return HorizontalDispatch.serialize(
                HorizontalDispatch.errorResponse(id: request["id"], code: .authFailed, message: "Unauthorized: the request's auth token does not match live.json.", data: ["code": "AUTH_FAILED", "retryable": false, "outcome": "not_committed"]),
                pretty: false
            )
        }
        request.removeValue(forKey: "auth")
        HorizontalDispatchSession.shared.syncLiveEntries()
        return HorizontalDispatch.serialize(HorizontalDispatch.call(request), pretty: false)
    }

    /// The requests that wait for a pending plane pour before they run.
    nonisolated static let planeFillReaders: Set<String> = ["export", "check"]
    /// How long such a request waits before it reads the fills as they are.
    nonisolated static let planePourWaitLimit: TimeInterval = 120

    nonisolated static func readsPlaneFills(line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? JSONDictionary,
              let method = request["method"] as? String else {
            return false
        }
        return planeFillReaders.contains(method)
    }

    /// Capture on the main actor, then evaluate model-only queries on the
    /// connection queue. Rendering/export retain their audited main-actor path.
    static func prepareRead(line: String, expectedToken: String) -> (@Sendable () -> String)? {
        let eligible: Set<String> = ["project_info", "project_files", "list_sheets", "list_components", "get_component", "list_nets", "get_net", "netlist", "bom", "list_parts", "board_info", "list_groups", "analysis_snapshot"]
        guard let data = line.data(using: .utf8),
              var request = (try? JSONSerialization.jsonObject(with: data)) as? JSONDictionary,
              request.string("auth") == expectedToken, let method = request.string("method"), eligible.contains(method),
              let params = request.dictionary("params"), let handle = params.int("handle") else { return nil }
        HorizontalDispatchSession.shared.syncLiveEntries()
        guard let session = try? HorizontalDispatchSession.shared.perform({ try $0.detachedReadSession(handle: handle) }) else { return nil }
        request.removeValue(forKey: "auth")
        let input = HorizontalUnsafeSendableBox(request)
        return { HorizontalDispatch.serialize(HorizontalDispatch.call(input.value, in: session), pretty: false) }
    }
}

#if canImport(Network) && os(macOS)
@MainActor
final class HorizontalLiveListener {
    static let shared = HorizontalLiveListener()

    private(set) var port: UInt16?
    private(set) var token: String?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HorizontalLiveConnection] = [:]
    private let queue = DispatchQueue(label: "com.twarge.horizontal.live-server", qos: .userInitiated)

    func start() {
        guard listener == nil else {
            return
        }
        let token = Self.makeToken()
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            NSLog("Horizontal live channel: could not create the listener.")
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.listenerStateChanged(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            // Before the hop to the main actor, which App Nap may be holding
            // back: see HorizontalLiveActivity.
            HorizontalLiveActivity.shared.connectionOpened()
            Task { @MainActor in
                self?.accept(connection, token: token)
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        guard let listener else {
            return
        }
        listener.cancel()
        self.listener = nil
        for connection in connections.values {
            connection.cancel()
            HorizontalLiveActivity.shared.connectionClosed()
        }
        connections.removeAll()
        port = nil
        token = nil
        try? FileManager.default.removeItem(at: HorizontalLiveServer.discoveryURL)
        HorizontalLiveServer.endpointDidChange()
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            writeDiscoveryFile()
            HorizontalLiveServer.endpointDidChange()
        case .failed(let error):
            NSLog("Horizontal live channel failed: \(error.localizedDescription)")
            stop()
        case .cancelled:
            port = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, token: String) {
        guard listener != nil, connections.count < 16 else {
            connection.cancel()
            HorizontalLiveActivity.shared.connectionClosed()
            return
        }
        let live = HorizontalLiveConnection(connection: connection, token: token, queue: queue) { [weak self] finished in
            Task { @MainActor in
                // A connection reports failing and then being cancelled; it
                // closes once.
                if self?.connections.removeValue(forKey: ObjectIdentifier(finished)) != nil {
                    HorizontalLiveActivity.shared.connectionClosed()
                }
            }
        }
        connections[ObjectIdentifier(live)] = live
        live.start()
    }

    private func writeDiscoveryFile() {
        guard let port, let token else {
            return
        }
        let url = HorizontalLiveServer.discoveryURL
        let json: JSONDictionary = [
            "version": HorizontalDispatch.apiVersion,
            "host": "127.0.0.1",
            "port": Int(port),
            "token": token,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "started": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Horizontal live channel: could not write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps the app out of App Nap while a live client is connected (item
/// 155). Napping, the app runs at background priority, and on a loaded
/// machine — Xcode building, tests running — a request waited 12–16 s for
/// the main thread with the app idle at 0.4% CPU, until the client gave up
/// and closed the connection, failing the calls queued behind it. The
/// activity each request already took began only once the request was read,
/// at nap priority. An MCP client holds its connection for the session, so
/// this holds for as long as an agent works with the app, and lets go when
/// the last connection closes. It keeps no thread busy, and allows idle
/// system sleep.
final class HorizontalLiveActivity: @unchecked Sendable {
    static let shared = HorizontalLiveActivity()

    private let lock = NSLock()
    private var connections = 0
    private var activity: NSObjectProtocol?

    /// Whether the app is being kept awake for a client; for tests.
    var isHeld: Bool {
        lock.withLock { activity != nil }
    }

    func connectionOpened() {
        lock.withLock {
            connections += 1
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "A client is connected to the live channel"
                )
            }
        }
    }

    func connectionClosed() {
        lock.withLock {
            connections = max(0, connections - 1)
            if connections == 0, let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
    }
}

/// One client connection: buffers bytes into lines and answers each line in
/// order on the main actor.
final class HorizontalLiveConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let queue: DispatchQueue
    private let onFinish: (HorizontalLiveConnection) -> Void
    private var buffer = Data()

    init(connection: NWConnection, token: String, queue: DispatchQueue, onFinish: @escaping (HorizontalLiveConnection) -> Void) {
        self.connection = connection
        self.token = token
        self.queue = queue
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .failed, .cancelled:
                self.onFinish(self)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                guard self.buffer.count <= 16 * 1024 * 1024 else {
                    self.connection.cancel()
                    return
                }
                self.drainLines()
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else {
                continue
            }
            // Requests are answered in order, and dispatch runs on the main
            // actor because live documents live there. The connection queue
            // waits for each answer rather than interleaving them.
            //
            // A client works while the app is in the background, where App Nap
            // runs the main thread at background priority (ps shows PRI 4): a
            // dry run on a large board took three times as long as the same
            // work done headless. A user-initiated activity for the length of
            // the request keeps it at the priority the user's own edits get.
            let token = self.token
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Answering a live channel request"
            )
            // An export or a check reads the plane fills. One that comes in
            // while a pour is asked for or running (the edit before it set
            // one off) waits here, on this queue, for the pour to land on the
            // main thread, and reads the fills the board has then.
            if HorizontalLiveServer.readsPlaneFills(line: line) {
                HorizontalPlanePourActivity.shared.waitUntilIdle(timeout: HorizontalLiveServer.planePourWaitLimit)
            }
            let execute: @Sendable () -> String = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    if let read = HorizontalLiveServer.prepareRead(line: line, expectedToken: token) { return read }
                    let response = HorizontalLiveServer.handle(line: line, expectedToken: token)
                    return { response }
                }
            }
            let response = execute()
            ProcessInfo.processInfo.endActivity(activity)
            connection.send(content: Data((response + "\n").utf8), completion: .contentProcessed { _ in })
        }
    }
}
#endif
