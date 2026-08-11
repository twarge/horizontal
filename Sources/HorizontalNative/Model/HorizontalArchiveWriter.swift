import Foundation
import Compression

/// Self-contained ZIP and gzip/tar (`.tgz`) archive writers.
///
/// Exports used to shell out to `/usr/bin/zip`, `/usr/bin/tar` and `/usr/bin/ditto`
/// to bundle Gerber and ODB++ output — which is unavailable in the iOS sandbox (no
/// `Process`). This builds the archive containers in-process instead: DEFLATE/gzip
/// compression comes from Apple's `Compression` framework (macOS + iOS), while CRC-32
/// and the ZIP/TAR/gzip byte layouts are assembled here.
///
/// The output is a delivery artifact (Gerbers/ODB++ for a fab), not the Horizon
/// on-disk project format, so byte-parity with the previous `/usr/bin/zip` output is
/// not required — only that the archive is valid and round-trips its contents exactly.
enum HorizontalArchiveWriter {
    /// One member of an archive. `path` is a POSIX (forward-slash) path; directory
    /// entries end in `/` and carry no data.
    struct Entry {
        var path: String
        var data: Data
        var isDirectory: Bool

        init(path: String, data: Data = Data(), isDirectory: Bool = false) {
            self.path = path
            self.data = data
            self.isDirectory = isDirectory
        }
    }

    // MARK: - Entry collection

    /// Entries for a flat list of files (no directories), keyed by base name — the
    /// equivalent of `zip -j` (junk paths).
    static func flatFileEntries(_ files: [URL]) throws -> [Entry] {
        try files.map { Entry(path: $0.lastPathComponent, data: try Data(contentsOf: $0)) }
    }

    /// Entries for a directory tree, each prefixed with `topLevelName` so the archive
    /// keeps the parent folder (the equivalent of `tar -C <parent> <name>` or
    /// `ditto --keepParent`). Includes directory entries for compatibility.
    static func directoryTreeEntries(root: URL, topLevelName: String) throws -> [Entry] {
        let fileManager = FileManager.default
        var entries: [Entry] = [Entry(path: topLevelName + "/", isDirectory: true)]

        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return entries
        }

        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let fullPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            var relative = String(fullPath.dropFirst(rootPath.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }
            let archivePath = topLevelName + "/" + relative
            if isDirectory {
                entries.append(Entry(path: archivePath + "/", isDirectory: true))
            } else {
                entries.append(Entry(path: archivePath, data: try Data(contentsOf: url)))
            }
        }
        return entries
    }

    // MARK: - ZIP

    /// Builds a ZIP archive (PKWARE APPNOTE: local headers, then the central
    /// directory, then the end-of-central-directory record). Each member is stored
    /// with DEFLATE (method 8) when that shrinks it, else uncompressed (method 0).
    static func zipData(entries: [Entry]) throws -> Data {
        // This writer is not ZIP64: sizes/offsets are 32-bit and the entry count is
        // 16-bit. That covers every Gerber/ODB++ fab export (far below 4 GB / 65535
        // files); rather than silently wrap-around into a corrupt archive past those
        // limits, fail loudly.
        guard entries.count <= 0xFFFE else {
            throw HorizontalArchiveError("ZIP archives are limited to 65,535 entries (got \(entries.count)).")
        }
        var output = Data()
        var central = Data()
        var count: UInt16 = 0

        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            // General-purpose bit 11 declares the name is UTF-8 (for non-ASCII paths).
            let flags: UInt16 = nameBytes.contains { $0 >= 0x80 } ? 0x0800 : 0
            guard entry.data.count <= 0xFFFF_FFFE else {
                throw HorizontalArchiveError("Entry \"\(entry.path)\" is too large for a non-ZIP64 archive (\(entry.data.count) bytes).")
            }
            let crc = crc32(entry.data)
            let uncompressedSize = UInt32(truncatingIfNeeded: entry.data.count)

            let method: UInt16
            let payload: Data
            if entry.isDirectory || entry.data.isEmpty {
                method = 0
                payload = Data()
            } else if let deflated = deflate(entry.data), deflated.count < entry.data.count {
                method = 8
                payload = deflated
            } else {
                method = 0
                payload = entry.data
            }
            guard output.count <= 0xFFFF_FFFE else {
                throw HorizontalArchiveError("ZIP archive exceeds the 4 GB limit (ZIP64 is not supported).")
            }
            let compressedSize = UInt32(truncatingIfNeeded: payload.count)
            let localOffset = UInt32(truncatingIfNeeded: output.count)

            // Local file header (signature 0x04034b50).
            output.appendLE(UInt32(0x04034b50))
            output.appendLE(UInt16(20))                 // version needed to extract (2.0)
            output.appendLE(flags)                      // general purpose flags
            output.appendLE(method)                     // compression method
            output.appendLE(UInt16(0))                  // last mod file time
            output.appendLE(UInt16(0x21))               // last mod file date (1980-01-01)
            output.appendLE(crc)
            output.appendLE(compressedSize)
            output.appendLE(uncompressedSize)
            output.appendLE(UInt16(nameBytes.count))    // file name length
            output.appendLE(UInt16(0))                  // extra field length
            output.append(contentsOf: nameBytes)
            output.append(payload)

            // Central directory file header (signature 0x02014b50).
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(0x031E))            // version made by (Unix, 3.0)
            central.appendLE(UInt16(20))                // version needed to extract
            central.appendLE(flags)                     // general purpose flags
            central.appendLE(method)
            central.appendLE(UInt16(0))                 // last mod file time
            central.appendLE(UInt16(0x21))              // last mod file date
            central.appendLE(crc)
            central.appendLE(compressedSize)
            central.appendLE(uncompressedSize)
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))                 // extra field length
            central.appendLE(UInt16(0))                 // file comment length
            central.appendLE(UInt16(0))                 // disk number start
            central.appendLE(UInt16(0))                 // internal file attributes
            central.appendLE(externalAttributes(isDirectory: entry.isDirectory))
            central.appendLE(localOffset)
            central.append(contentsOf: nameBytes)

            count &+= 1
        }

        guard output.count <= 0xFFFF_FFFE, central.count <= 0xFFFF_FFFE else {
            throw HorizontalArchiveError("ZIP archive exceeds the 4 GB limit (ZIP64 is not supported).")
        }
        let centralOffset = UInt32(truncatingIfNeeded: output.count)
        output.append(central)
        let centralSize = UInt32(truncatingIfNeeded: central.count)

        // End of central directory record (signature 0x06054b50).
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))                      // number of this disk
        output.appendLE(UInt16(0))                      // disk with central directory
        output.appendLE(count)                          // entries on this disk
        output.appendLE(count)                          // total entries
        output.appendLE(centralSize)
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))                      // .ZIP comment length
        return output
    }

    /// Unix mode bits in the high word of the external-attributes field (honoured
    /// because "version made by" advertises Unix); the low byte sets the MS-DOS
    /// directory attribute so DOS-style readers also treat folders correctly.
    private static func externalAttributes(isDirectory: Bool) -> UInt32 {
        if isDirectory {
            return (UInt32(0o040755) << 16) | 0x10
        } else {
            return UInt32(0o100644) << 16
        }
    }

    // MARK: - tar.gz

    /// Builds a gzip-compressed POSIX (ustar) tar archive (`.tgz`).
    static func targzData(entries: [Entry]) throws -> Data {
        gzip(try tarData(entries: entries))
    }

    /// POSIX ustar tar: a 512-byte header per member, file data padded to 512-byte
    /// blocks, terminated by two zero blocks.
    static func tarData(entries: [Entry]) throws -> Data {
        var output = Data()
        for entry in entries {
            output.append(try tarHeader(for: entry))
            if !entry.isDirectory && !entry.data.isEmpty {
                output.append(entry.data)
                let remainder = entry.data.count % 512
                if remainder != 0 {
                    output.append(Data(repeating: 0, count: 512 - remainder))
                }
            }
        }
        output.append(Data(repeating: 0, count: 1024)) // end-of-archive marker
        return output
    }

    private static func tarHeader(for entry: Entry) throws -> Data {
        var header = [UInt8](repeating: 0, count: 512)

        func put(_ string: String, at offset: Int, width: Int) {
            for (i, byte) in Array(string.utf8).prefix(width).enumerated() {
                header[offset + i] = byte
            }
        }
        // Numeric tar fields: zero-padded octal in (width - 1) digits + a NUL.
        func putOctal(_ value: Int, at offset: Int, width: Int) {
            put(String(format: "%0\(width - 1)o", value), at: offset, width: width - 1)
            // remaining byte stays NUL
        }

        var name = entry.path
        if entry.isDirectory && !name.hasSuffix("/") { name += "/" }

        // ustar splits long names into a 155-byte prefix + 100-byte name at a "/".
        var prefix = ""
        if name.utf8.count > 100 {
            let chars = Array(name)
            var splitIndex: Int?
            // Largest split where name part fits in 100 and prefix fits in 155.
            for i in chars.indices where chars[i] == "/" {
                let head = String(chars[..<i])
                let tail = String(chars[(i + 1)...])
                if tail.utf8.count <= 100 && head.utf8.count <= 155 {
                    splitIndex = i
                    break
                }
            }
            if let splitIndex {
                prefix = String(chars[..<splitIndex])
                name = String(chars[(splitIndex + 1)...])
            }
        }

        // ustar can't represent a >100-byte name with no <=155/<=100 split, or a
        // size beyond the 11-octal-digit field (~8 GB). Neither happens for ODB++
        // output; fail loudly rather than silently truncate the name or size.
        guard name.utf8.count <= 100, prefix.utf8.count <= 155 else {
            throw HorizontalArchiveError("Archive path \"\(entry.path)\" is too long for the tar format.")
        }
        guard entry.isDirectory || entry.data.count <= 0o77_777_777_777 else {
            throw HorizontalArchiveError("Entry \"\(entry.path)\" exceeds the 8 GB tar size limit.")
        }

        put(name, at: 0, width: 100)                    // name
        putOctal(entry.isDirectory ? 0o755 : 0o644, at: 100, width: 8) // mode
        putOctal(0, at: 108, width: 8)                  // uid
        putOctal(0, at: 116, width: 8)                  // gid
        putOctal(entry.isDirectory ? 0 : entry.data.count, at: 124, width: 12) // size
        putOctal(0, at: 136, width: 12)                 // mtime
        for i in 148..<156 { header[i] = 0x20 }         // checksum field = spaces while summing
        header[156] = entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0") // typeflag
        put("ustar", at: 257, width: 6)                 // magic "ustar\0"
        header[263] = UInt8(ascii: "0")                 // version "00"
        header[264] = UInt8(ascii: "0")
        if !prefix.isEmpty {
            put(prefix, at: 345, width: 155)
        }

        // Header checksum: sum of all 512 bytes, as 6 octal digits + NUL + space.
        let checksum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", checksum), at: 148, width: 6)
        header[154] = 0
        header[155] = 0x20

        return Data(header)
    }

    // MARK: - gzip (RFC 1952)

    private static func gzip(_ data: Data) -> Data {
        var output = Data()
        output.append(contentsOf: [
            0x1f, 0x8b,             // magic
            0x08,                   // compression method = DEFLATE
            0x00,                   // flags
            0x00, 0x00, 0x00, 0x00, // mtime = 0
            0x00,                   // extra flags
            0xff,                   // OS = unknown
        ])
        output.append(deflate(data) ?? deflateStored(data))
        output.appendLE(crc32(data))
        output.appendLE(UInt32(truncatingIfNeeded: data.count))
        return output
    }

    // MARK: - DEFLATE (RFC 1951) via the Compression framework

    /// Raw DEFLATE stream, or `nil` if compression failed or wouldn't fit (the caller
    /// falls back to stored). `COMPRESSION_ZLIB` emits a raw DEFLATE bitstream — no
    /// zlib header/checksum — which is exactly what ZIP method 8 and gzip require.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // Worst-case DEFLATE output is the input plus a ~5-byte stored-block header
        // per 64 KB (incompressible data); size for that so compression of large
        // incompressible members isn't forced to stored by a too-small buffer.
        let capacity = data.count + (data.count / 65535 + 1) * 5 + 64
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source -> Int in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                &destination, capacity,
                sourceBase, data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(destination.prefix(written))
    }

    /// Wraps bytes in uncompressed DEFLATE "stored" blocks (≤65535 bytes each). Used
    /// only as a gzip fallback for incompressible data, so the gzip body is always a
    /// valid DEFLATE stream.
    private static func deflateStored(_ data: Data) -> Data {
        var output = Data()
        let bytes = [UInt8](data)
        if bytes.isEmpty {
            output.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff]) // final empty stored block
            return output
        }
        var offset = 0
        while offset < bytes.count {
            let chunk = min(65535, bytes.count - offset)
            let isFinal = offset + chunk >= bytes.count
            output.append(isFinal ? 0x01 : 0x00)        // BFINAL + BTYPE=00 (byte-aligned)
            let len = UInt16(chunk)
            output.appendLE(len)
            output.appendLE(~len)
            output.append(contentsOf: bytes[offset ..< offset + chunk])
            offset += chunk
        }
        return output
    }

    // MARK: - CRC-32 (IEEE 802.3, reflected)

    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        var c = UInt32(index)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

struct HorizontalArchiveError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
