import Foundation

/// The parts of git's smart HTTP protocol (version 0, which every server
/// speaks) a clone needs: the pkt-line framing, the server's advertisement of
/// its refs and capabilities, the request for a pack, and the side-band
/// framing the pack comes back in. Documented in git's
/// `Documentation/gitprotocol-pack.txt` and `gitprotocol-http.txt`.
enum HorizontalGitProtocol {
    /// One pkt-line: four hex digits of length (counting themselves) and the
    /// payload; "0000" is a flush.
    static func pktLine(_ payload: String) -> Data {
        pktLine(Data(payload.utf8))
    }

    static func pktLine(_ payload: Data) -> Data {
        var line = Data(String(format: "%04x", payload.count + 4).utf8)
        line.append(payload)
        return line
    }

    static let flush = Data("0000".utf8)

    /// The pkt-lines in `data` from `offset`: each payload, or nil for a
    /// flush. Stops at the end of the data.
    static func pktLines(_ data: Data, from offset: Int = 0) throws -> [Data?] {
        var lines = [Data?]()
        var cursor = offset
        let bytes = [UInt8](data)
        while cursor + 4 <= bytes.count {
            guard let length = Int(String(decoding: bytes[cursor..<cursor + 4], as: UTF8.self), radix: 16) else {
                throw HorizontalGitCloneError.protocolError("A malformed pkt-line length")
            }
            if length == 0 {
                lines.append(nil)
                cursor += 4
                continue
            }
            guard length >= 4, cursor + length <= bytes.count else {
                throw HorizontalGitCloneError.protocolError("A pkt-line runs past the end of the response")
            }
            lines.append(Data(bytes[cursor + 4..<cursor + length]))
            cursor += length
        }
        return lines
    }

    /// The server's refs and what it can do, from `info/refs?service=git-upload-pack`.
    struct Advertisement: Equatable {
        var refs: [(name: String, id: String)]
        var capabilities: Set<String>

        static func == (lhs: Advertisement, rhs: Advertisement) -> Bool {
            lhs.refs.map(\.name) == rhs.refs.map(\.name) && lhs.refs.map(\.id) == rhs.refs.map(\.id)
                && lhs.capabilities == rhs.capabilities
        }

        /// The branch HEAD points to, from the `symref=HEAD:` capability.
        var headBranch: String? {
            capabilities.first { $0.hasPrefix("symref=HEAD:") }.map { String($0.dropFirst("symref=HEAD:".count)) }
        }

        func id(of ref: String) -> String? {
            refs.first { $0.name == ref }?.id
        }
    }

    static func advertisement(from data: Data) throws -> Advertisement {
        var lines = try pktLines(data)
        // The smart reply starts with "# service=git-upload-pack" and a flush;
        // a dumb server's plain text has neither.
        guard let first = lines.first, let service = first,
              String(decoding: service, as: UTF8.self).hasPrefix("# service=git-upload-pack") else {
            throw HorizontalGitCloneError.protocolError("The server doesn't speak git's smart HTTP protocol")
        }
        lines.removeFirst()
        if lines.first == .some(nil) {
            lines.removeFirst()
        }
        var refs = [(name: String, id: String)]()
        var capabilities = Set<String>()
        for case let line? in lines {
            var text = String(decoding: line, as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            var refPart = Substring(text)
            if let nul = text.firstIndex(of: "\0") {
                refPart = text[..<nul]
                capabilities.formUnion(text[text.index(after: nul)...].split(separator: " ").map(String.init))
            }
            let fields = refPart.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2, fields[0].count == 40 else { continue }
            // "capabilities^{}" stands in for the refs of an empty repository,
            // and "^{}" lines are tags peeled to what they point at.
            guard fields[1] != "capabilities^{}", !fields[1].hasSuffix("^{}") else { continue }
            refs.append((name: fields[1], id: fields[0]))
        }
        return Advertisement(refs: refs, capabilities: capabilities)
    }

    /// The side-band the pack is asked to come in, from what the server offers.
    enum SideBand: Equatable {
        case none
        case small   // side-band: 1000-byte packets
        case large   // side-band-64k

        init(_ capabilities: Set<String>) {
            if capabilities.contains("side-band-64k") { self = .large }
            else if capabilities.contains("side-band") { self = .small }
            else { self = .none }
        }

        var capability: String? {
            switch self {
            case .none: nil
            case .small: "side-band"
            case .large: "side-band-64k"
            }
        }
    }

    /// The body of a `git-upload-pack` request for a fresh clone of `want`:
    /// no haves, so the server answers NAK and sends the whole history.
    /// `haves` are commits the client has, for a fetch into a clone: the
    /// server answers with a pack of only what they lack. It isn't asked for
    /// a thin pack, so every delta's base is in the pack.
    static func uploadPackRequest(want: String, haves: [String] = [], capabilities offered: Set<String>) -> Data {
        var asked = [String]()
        if let band = SideBand(offered).capability { asked.append(band) }
        if offered.contains("ofs-delta") { asked.append("ofs-delta") }
        asked.append("agent=horizontal/1")
        var body = pktLine("want \(want) \(asked.joined(separator: " "))\n")
        body.append(flush)
        for have in haves {
            body.append(pktLine("have \(have)\n"))
        }
        body.append(pktLine("done\n"))
        return body
    }

    /// The pack in an upload-pack reply: after the NAK, either the raw pack
    /// or side-band packets whose band 1 is the pack, band 2 progress text
    /// and band 3 an error.
    static func pack(fromUploadPackResponse data: Data, sideBand: SideBand) throws -> Data {
        let bytes = [UInt8](data)
        var cursor = 0
        // The NAK (or ACK) lines before the pack.
        while cursor + 4 <= bytes.count {
            guard let length = Int(String(decoding: bytes[cursor..<cursor + 4], as: UTF8.self), radix: 16), length >= 4,
                  cursor + length <= bytes.count else { break }
            let payload = String(decoding: bytes[cursor + 4..<cursor + length], as: UTF8.self)
            guard payload.hasPrefix("NAK") || payload.hasPrefix("ACK") else { break }
            cursor += length
        }
        if sideBand == .none {
            return Data(bytes[cursor...])
        }
        var pack = Data()
        pack.reserveCapacity(bytes.count)
        while cursor + 4 <= bytes.count {
            guard let length = Int(String(decoding: bytes[cursor..<cursor + 4], as: UTF8.self), radix: 16) else {
                throw HorizontalGitCloneError.protocolError("A malformed side-band packet")
            }
            if length == 0 { break }
            guard length > 4, cursor + length <= bytes.count else {
                throw HorizontalGitCloneError.protocolError("A side-band packet runs past the end of the response")
            }
            let band = bytes[cursor + 4]
            let payload = bytes[cursor + 5..<cursor + length]
            switch band {
            case 1: pack.append(contentsOf: payload)
            case 3: throw HorizontalGitCloneError.server(String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            default: break
            }
            cursor += length
        }
        return pack
    }
}

enum HorizontalGitCloneError: LocalizedError, Equatable {
    case protocolError(String)
    case server(String)
    case http(Int)
    case corruptPack(String)
    case destinationNotEmpty(String)
    case noBranch

    var errorDescription: String? {
        switch self {
        case .protocolError(let detail): "The git server's reply couldn't be read: \(detail)."
        case .server(let message): "The git server reported an error: \(message)"
        case .http(let status): "The git server answered HTTP \(status)."
        case .corruptPack(let detail): "The repository's data didn't check out: \(detail)."
        case .destinationNotEmpty(let path): "\(path) already exists and isn't empty."
        case .noBranch: "The repository has no branch to check out."
        }
    }
}
