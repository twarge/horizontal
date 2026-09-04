import Foundation
import HorizontalProjectIO
import XCTest

/// Load → write → compare over the whole stock pool, one kind at a time.
///
/// A file Horizon itself wrote comes back byte for byte. Files that were
/// hand-edited or produced by other tools (CRLF line endings, tab indentation,
/// `×`-style escapes, a trailing newline, minified generator output, scripts
/// that wrote keys in insertion order) legitimately re-serialise differently;
/// every file must at least be structurally equal after the rewrite, and the
/// byte-equal files must be the majority of each kind so a formatting
/// regression (which drops that count to zero) can't hide behind the rest.
///
/// Skipped when the checkout is absent, like the other stock-pool tests.
final class HorizontalPoolCorpusRoundTripTests: XCTestCase {
    private static let poolURL = URL(fileURLWithPath: "/Users/kornack/Repositories/horizon-pool", isDirectory: true)

    func testUnitsRoundTrip() throws { try roundTrip(kind: "units") }
    func testSymbolsRoundTrip() throws { try roundTrip(kind: "symbols") }
    func testEntitiesRoundTrip() throws { try roundTrip(kind: "entities") }
    func testPadstacksRoundTrip() throws { try roundTrip(kind: "padstacks") }
    func testPackagesRoundTrip() throws { try roundTrip(kind: "packages") }
    func testPartsRoundTrip() throws { try roundTrip(kind: "parts") }
    func testFramesRoundTrip() throws { try roundTrip(kind: "frames") }
    func testDecalsRoundTrip() throws { try roundTrip(kind: "decals") }

    private func roundTrip(kind: String) throws {
        let directory = Self.poolURL.appendingPathComponent(kind, isDirectory: true)
        guard FileManager.default.fileExists(atPath: Self.poolURL.appendingPathComponent("pool.json").path),
              FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("stock horizon-pool checkout not available")
        }

        var byteEqual = 0
        var nonCanonical = 0
        var failures = [String]()
        var unexplained = [String]()
        var total = 0

        let skipped: Set<String> = ["3d_models", "tmp", "scripts"]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == "json" else {
                continue
            }
            total += 1
            let original = try Data(contentsOf: url)
            let relative = url.path.dropFirst(Self.poolURL.path.count + 1)
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                failures.append("\(relative): not an object")
                continue
            }
            let written = try HorizontalHorizonJSONWriter.data(object)
            if written == original {
                byteEqual += 1
                continue
            }
            let reparsed = try JSONSerialization.jsonObject(with: written) as? [String: Any]
            guard let reparsed, NSDictionary(dictionary: reparsed) == NSDictionary(dictionary: object) else {
                failures.append("\(relative): rewrite changed the content — \(Self.firstDifference(original, written))")
                continue
            }
            if Self.isRecognisablyNonCanonical(original) {
                nonCanonical += 1
            } else {
                unexplained.append("\(relative): \(Self.firstDifference(original, written))")
            }
        }

        XCTAssertGreaterThan(total, 0, "\(kind) has no files")
        XCTAssertEqual(failures, [], "\(kind): \(failures.count) of \(total) files lost content on rewrite")
        XCTAssertGreaterThan(
            byteEqual * 2, total,
            "\(kind): only \(byteEqual) of \(total) files came back byte-identical; the writer's format drifted"
        )
        print("[corpus] \(kind): \(total) files, \(byteEqual) byte-equal, \(nonCanonical) recognisably non-canonical, \(unexplained.count) other formatting differences")
        for line in unexplained.prefix(5) {
            print("[corpus]   \(line)")
        }
    }

    /// Bytes Horizon's own writer never produces: CR, tabs, `\u` escapes, a
    /// trailing newline, or anything but `{` + newline + four spaces up front
    /// (minified output). Key-order deviations from scripted writers are not
    /// detectable cheaply and land in the "other" bucket.
    private static func isRecognisablyNonCanonical(_ data: Data) -> Bool {
        if data.last == 0x0A || data.contains(0x0D) || data.contains(0x09) {
            return true
        }
        if !data.starts(with: Array("{\n    \"".utf8)) {
            return true
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("\\u")
    }

    private static func firstDifference(_ a: Data, _ b: Data) -> String {
        let index = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
        let start = max(0, index - 20)
        func excerpt(_ data: Data) -> String {
            let end = min(data.count, index + 20)
            guard start < end else {
                return ""
            }
            return String(decoding: data[start..<end], as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "⏎")
        }
        return "differs at byte \(index): original …\(excerpt(a))… written …\(excerpt(b))…"
    }
}
