import XCTest
import Compression
@testable import HorizontalNative

final class HorizontalArchiveWriterTests: XCTestCase {

    // MARK: - CRC-32

    func testCRC32KnownVectors() {
        XCTAssertEqual(HorizontalArchiveWriter.crc32(Data()), 0)
        // The canonical CRC-32 check value for the ASCII string "123456789".
        XCTAssertEqual(HorizontalArchiveWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - ZIP, validated by parsing + inflating in-process

    func testZipRoundTripInProcess() throws {
        let entries: [HorizontalArchiveWriter.Entry] = [
            .init(path: "readme.txt", data: Data(String(repeating: "Gerber RS-274X\n", count: 500).utf8)),
            .init(path: "empty.txt", data: Data()),
            .init(path: "random.bin", data: Self.incompressibleData(count: 4096)),
            .init(path: "job/", isDirectory: true),
            .init(path: "job/top.gbr", data: Data("G04 hello*\n".utf8)),
        ]
        let archive = try HorizontalArchiveWriter.zipData(entries: entries)

        let parsed = try Self.parseZip(archive)
        XCTAssertEqual(parsed.map(\.name), entries.map(\.path))

        for (decoded, original) in zip(parsed, entries) {
            XCTAssertEqual(decoded.uncompressedSize, original.data.count, "size of \(original.path)")
            XCTAssertEqual(decoded.crc, HorizontalArchiveWriter.crc32(original.data), "crc of \(original.path)")

            let payload: Data
            switch decoded.method {
            case 0:
                payload = decoded.compressed
            case 8:
                payload = try XCTUnwrap(
                    Self.inflate(decoded.compressed, expectedSize: decoded.uncompressedSize),
                    "inflate \(original.path)"
                )
            default:
                return XCTFail("unexpected method \(decoded.method) for \(original.path)")
            }
            XCTAssertEqual(payload, original.data, "content of \(original.path)")
            // Incompressible data must fall back to stored (method 0), not expand.
            if original.path == "random.bin" {
                XCTAssertEqual(decoded.method, 0)
            }
        }
    }

    func testZipChoosesDeflateForCompressibleData() throws {
        let compressible = Data(String(repeating: "AAAA", count: 5000).utf8)
        let zip = try HorizontalArchiveWriter.zipData(entries: [.init(path: "a.txt", data: compressible)])
        let parsed = try Self.parseZip(zip)
        XCTAssertEqual(parsed.first?.method, 8, "highly repetitive data should DEFLATE")
        XCTAssertLessThan(parsed.first?.compressed.count ?? .max, compressible.count)
    }

    func testZipNonASCIINameSetsUTF8FlagAndUnpacks() throws {
        let name = "café/naïve—layer.gbr"
        let payload = Data(String(repeating: "data ", count: 1000).utf8)
        let archive = try HorizontalArchiveWriter.zipData(entries: [
            .init(path: "café/", isDirectory: true),
            .init(path: name, data: payload),
        ])
        let parsed = try Self.parseZip(archive)
        let fileEntry = try XCTUnwrap(parsed.first { $0.name == name })
        XCTAssertEqual(fileEntry.flags & 0x0800, 0x0800, "non-ASCII names must set the UTF-8 flag")

        let ascii = try XCTUnwrap(parsed.first { $0.name == "café/" })
        XCTAssertEqual(ascii.flags & 0x0800, 0x0800, "the café/ dir name is also non-ASCII")

        #if os(macOS)
        let dir = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("utf8.zip")
        try archive.write(to: zipURL)
        XCTAssertEqual(try Self.run("/usr/bin/unzip", ["-t", zipURL.path]).status, 0)
        #endif
    }

    func testTarRejectsUnrepresentableLongName() {
        // A single >100-byte path component has no "/" to split on, so ustar can't
        // represent it — the writer must throw rather than silently truncate.
        let name = String(repeating: "x", count: 130)
        XCTAssertThrowsError(
            try HorizontalArchiveWriter.targzData(entries: [.init(path: name, data: Data("x".utf8))])
        )
    }

    func testTarLongButSplittablePathUnpacks() throws {
        #if os(macOS)
        // ~135-byte path with slashes: splits into a <=155 prefix + <=100 name and
        // must round-trip through real tar with the full path intact.
        let path = String(repeating: "abcdefghij/", count: 12) + "f.txt" // 12*11 + 5 = 137 bytes
        XCTAssertGreaterThan(path.utf8.count, 100)
        let payload = Data("deep payload".utf8)
        let targz = try HorizontalArchiveWriter.targzData(entries: [.init(path: path, data: payload)])

        let dir = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("deep.tgz")
        try targz.write(to: outURL)
        let extractDir = dir.appendingPathComponent("extract")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        XCTAssertEqual(try Self.run("/usr/bin/tar", ["-xzf", outURL.path, "-C", extractDir.path]).status, 0)
        XCTAssertEqual(try Data(contentsOf: extractDir.appendingPathComponent(path)), payload)
        #else
        throw XCTSkip("System tar is only available on the macOS host.")
        #endif
    }

    // MARK: - Validation against the real /usr/bin tools (macOS host only)

    func testZipUnpacksWithSystemUnzip() throws {
        #if os(macOS)
        let files: [(String, Data)] = [
            ("alpha.gbr", Data("G04 alpha layer*\n".utf8)),
            ("beta.drl", Self.incompressibleData(count: 9000)),
            ("gamma.txt", Data(String(repeating: "repeat ", count: 3000).utf8)),
        ]
        let zip = try HorizontalArchiveWriter.zipData(entries: files.map { .init(path: $0.0, data: $0.1) })

        let dir = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("out.zip")
        try zip.write(to: zipURL)

        // `unzip -t` cryptographically (CRC) verifies every member.
        XCTAssertEqual(try Self.run("/usr/bin/unzip", ["-t", zipURL.path]).status, 0, "unzip -t must pass")

        let extractDir = dir.appendingPathComponent("extract")
        _ = try Self.run("/usr/bin/unzip", ["-o", "-q", zipURL.path, "-d", extractDir.path])
        for (name, data) in files {
            let extracted = try Data(contentsOf: extractDir.appendingPathComponent(name))
            XCTAssertEqual(extracted, data, "extracted \(name) must match")
        }
        #else
        throw XCTSkip("System unzip is only available on the macOS host.")
        #endif
    }

    func testTarGzUnpacksWithSystemTar() throws {
        #if os(macOS)
        let root = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("job")
        try FileManager.default.createDirectory(at: job.appendingPathComponent("steps"), withIntermediateDirectories: true)
        let f1 = job.appendingPathComponent("matrix.txt")
        let f2 = job.appendingPathComponent("steps/profile.txt")
        let d1 = Data(String(repeating: "ODB++ matrix line\n", count: 200).utf8)
        let d2 = Self.incompressibleData(count: 7000)
        try d1.write(to: f1)
        try d2.write(to: f2)

        let entries = try HorizontalArchiveWriter.directoryTreeEntries(root: job, topLevelName: "job")
        let targz = try HorizontalArchiveWriter.targzData(entries: entries)
        let outURL = root.appendingPathComponent("out.tgz")
        try targz.write(to: outURL)

        // `tar -tzf` lists + gunzips; failure is a non-zero exit.
        XCTAssertEqual(try Self.run("/usr/bin/tar", ["-tzf", outURL.path]).status, 0, "tar -tzf must pass")

        let extractDir = root.appendingPathComponent("extract")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        XCTAssertEqual(try Self.run("/usr/bin/tar", ["-xzf", outURL.path, "-C", extractDir.path]).status, 0)
        XCTAssertEqual(try Data(contentsOf: extractDir.appendingPathComponent("job/matrix.txt")), d1)
        XCTAssertEqual(try Data(contentsOf: extractDir.appendingPathComponent("job/steps/profile.txt")), d2)
        #else
        throw XCTSkip("System tar is only available on the macOS host.")
        #endif
    }

    // MARK: - Helpers

    /// Deterministic pseudo-random (LCG) bytes that DEFLATE can't shrink.
    private static func incompressibleData(count: Int) -> Data {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0 ..< count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return Data(bytes)
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&destination, expectedSize, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expectedSize else { return nil }
        return Data(destination.prefix(written))
    }

    private struct ParsedEntry {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressed: Data
        var uncompressedSize: Int
    }

    /// Minimal ZIP reader (central directory → local headers) for test verification.
    private static func parseZip(_ zip: Data) throws -> [ParsedEntry] {
        let bytes = [UInt8](zip)
        func le16(_ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
        func le32(_ at: Int) -> Int {
            Int(bytes[at]) | (Int(bytes[at + 1]) << 8) | (Int(bytes[at + 2]) << 16) | (Int(bytes[at + 3]) << 24)
        }

        var eocd = bytes.count - 22
        while eocd >= 0 {
            if bytes[eocd] == 0x50, bytes[eocd + 1] == 0x4b, bytes[eocd + 2] == 0x05, bytes[eocd + 3] == 0x06 {
                break
            }
            eocd -= 1
        }
        guard eocd >= 0 else { throw ArchiveTestError("no end-of-central-directory record") }

        let count = le16(eocd + 10)
        var pointer = le32(eocd + 16)
        var result: [ParsedEntry] = []
        for _ in 0 ..< count {
            guard bytes[pointer] == 0x50, bytes[pointer + 1] == 0x4b,
                  bytes[pointer + 2] == 0x01, bytes[pointer + 3] == 0x02 else {
                throw ArchiveTestError("bad central directory signature")
            }
            let flags = UInt16(le16(pointer + 8))
            let method = UInt16(le16(pointer + 10))
            let crc = UInt32(bitPattern: Int32(truncatingIfNeeded: le32(pointer + 16)))
            let compressedSize = le32(pointer + 20)
            let uncompressedSize = le32(pointer + 24)
            let nameLength = le16(pointer + 28)
            let extraLength = le16(pointer + 30)
            let commentLength = le16(pointer + 32)
            let localOffset = le32(pointer + 42)
            let name = String(bytes: bytes[(pointer + 46) ..< (pointer + 46 + nameLength)], encoding: .utf8) ?? ""

            guard bytes[localOffset] == 0x50, bytes[localOffset + 1] == 0x4b,
                  bytes[localOffset + 2] == 0x03, bytes[localOffset + 3] == 0x04 else {
                throw ArchiveTestError("bad local header signature for \(name)")
            }
            let localNameLength = le16(localOffset + 26)
            let localExtraLength = le16(localOffset + 28)
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            let compressed = Data(bytes[dataStart ..< dataStart + compressedSize])

            result.append(ParsedEntry(
                name: name,
                flags: flags,
                method: method,
                crc: crc,
                compressed: compressed,
                uncompressedSize: uncompressedSize
            ))
            pointer += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    private struct ArchiveTestError: Error { let message: String; init(_ m: String) { message = m } }

    #if os(macOS)
    private static func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
    #endif
}
