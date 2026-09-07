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
    private let queue = DispatchQueue(label: "com.twarge.horizontal.live-server")

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
        }
        connections.removeAll()
        port = nil
        token = nil
        try? FileManager.default.removeItem(at: HorizontalLiveServer.discoveryURL)
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            writeDiscoveryFile()
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
        guard connections.count < 16 else { connection.cancel(); return }
        let live = HorizontalLiveConnection(connection: connection, token: token, queue: queue) { [weak self] finished in
            Task { @MainActor in
                self?.connections.removeValue(forKey: ObjectIdentifier(finished))
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
            let token = self.token
            let execute: @Sendable () -> String = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    if let read = HorizontalLiveServer.prepareRead(line: line, expectedToken: token) { return read }
                    let response = HorizontalLiveServer.handle(line: line, expectedToken: token)
                    return { response }
                }
            }
            let response = execute()
            connection.send(content: Data((response + "\n").utf8), completion: .contentProcessed { _ in })
        }
    }
}
#endif
