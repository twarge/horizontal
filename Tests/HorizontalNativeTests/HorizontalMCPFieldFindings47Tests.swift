import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// MCP field findings 47: where `pool_write` puts what it writes (item 151
/// in billo's notes). Jude's DAC80504, written in October 21's Rotating Field
/// session, went into the project pool's cache, where it read as a copy whose
/// source pool was missing. A part the MCP makes is the project's own.
final class HorizontalMCPFieldFindings47Tests: XCTestCase {
    private struct Part {
        var items: [JSONDictionary]
        var part: String
        var unit: String
        var package: String
    }

    /// A two-pin part named `name` throughout: unit, entity and symbol take
    /// the name, the part it as its MPN, the package "<name>-PKG" and its
    /// padstack "<name> pad".
    private func part(_ name: String) -> Part {
        let pins = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        let pads = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        var unit = HorizontalPoolItemFactory.newUnit()
        unit.name = name
        for i in pins.indices {
            unit.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: String(i + 1), direction: .passive, alternateNames: [])
        }
        let entity = HorizontalPoolItemFactory.newEntity(for: unit)
        let gate = entity.gates.keys.first!
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        for i in pins.indices {
            symbol.pins[pins[i]] = HorizontalSymbolPin(id: pins[i], position: HorizontalPoint(x: 0, y: -Double(i) * 2_500_000),
                                                       length: 2_500_000, orientation: .left)
        }
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        padstack.name = "\(name) pad"
        let shape = UUID().uuidString.lowercased()
        padstack.shapes[shape] = HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])
        var package = HorizontalPoolItemFactory.newPackage()
        package.name = "\(name)-PKG"
        for i in pads.indices {
            package.pads[pads[i]] = HorizontalPad(id: pads[i], name: String(i + 1), padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: Double(i) * 1_600_000, y: 0), angle: 0, mirrored: false))
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        for i in pins.indices { part.padMap[pads[i]] = HorizontalPartPadMapEntry(gateID: gate, pinID: pins[i]) }
        return Part(items: [unit.json(), entity.json(), symbol.json(), padstack.json(), package.json(), part.json()],
                    part: part.uuid, unit: unit.uuid, package: package.uuid)
    }

    private var root: URL!
    private var session: HorizontalDispatchSession!
    private var handle = 0
    /// A resistor in Stock, a pool the project draws from.
    private var resistor: Part!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("field47-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HorizontalPoolRegistryStore.defaults = try XCTUnwrap(UserDefaults(suiteName: "HorizontalMCPFieldFindings47Tests-\(UUID().uuidString)"))
        HorizontalPoolLibrary.invalidateCache()
        HorizontalPoolPadstacks.invalidateCaches()

        let stock = root.appendingPathComponent("stock", isDirectory: true)
        try write(["type": "pool", "uuid": UUID().uuidString.lowercased(), "name": "Stock"], to: stock.appendingPathComponent("pool.json"))
        resistor = part("RC0603FR-0710KL")
        for (json, path) in zip(resistor.items, ["units/resistor.json", "entities/resistor.json", "symbols/resistor.json",
                                                 "padstacks/smd.json", "packages/r0603/package.json", "parts/res-10k.json"]) {
            try write(json, to: stock.appendingPathComponent(path))
        }
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: stock))

        let project = root.appendingPathComponent("Project.horizontal")
        try HorizontalProjectArchive.newProject().write(to: project)
        session = HorizontalDispatchSession()
        handle = try session.open(url: project).handle
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        HorizontalPoolPadstacks.invalidateCaches()
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ json: JSONDictionary, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(json).write(to: url)
    }

    private func result(_ method: String, _ args: JSONDictionary = [:]) throws -> Any {
        var params = args
        params["handle"] = handle
        if ["apply", "pool_write", "import_pool_part"].contains(method) {
            params["expected_revision"] = try session.entry(handle: handle).revision
            params["operation_id"] = UUID().uuidString
        }
        let response = try JSONHelper.loadDictionary(from: Data(HorizontalDispatch.serialize(HorizontalDispatch.call(
            ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], in: session), pretty: false).utf8))
        XCTAssertNil(response["error"], "\(method): \(response)")
        return try XCTUnwrap(response["result"])
    }

    /// The files a `pool_write` wrote, by their path in the project pool,
    /// sorted as the reply sorts them.
    private func poolWrite(_ items: [JSONDictionary]) throws -> [String] {
        let reply = try XCTUnwrap(try result("pool_write", ["items": items]) as? JSONDictionary)
        return (reply["written"] as? [String] ?? []).map { $0.hasPrefix("pool/") ? String($0.dropFirst("pool/".count)) : $0 }
    }

    private func poolFile(_ path: String) throws -> URL {
        try session.entry(handle: handle).project.baseURL.appendingPathComponent("pool").appendingPathComponent(path)
    }

    func testAPartNoPoolHasIsWrittenWhereTheAppSavesANewOne() throws {
        let widget = part("Widget-1")
        XCTAssertEqual(try poolWrite(widget.items), [
            "entities/widget-1.json", "packages/widget-1-pkg/package.json", "padstacks/widget-1-pad.json",
            "parts/widget-1.json", "symbols/widget-1.json", "units/widget-1.json",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try poolFile("parts/widget-1.json").path))

        // The project's own, not a cached copy of something missing.
        let review = try XCTUnwrap(try result("list_part_updates") as? JSONDictionary)
        let row = try XCTUnwrap(review.dictionaryArray("parts").first { $0.string("uuid") == widget.part }, "\(review)")
        XCTAssertEqual(row.string("status"), "projectOnly")
        XCTAssertEqual(row["in_attached_pool"] as? Bool, false)

        // It places like any other part, its package and padstack found.
        _ = try result("apply", ["ops": [["op": "ensure_component", "refdes": "U1", "part": widget.part],
                                         ["op": "place_component", "component": "U1", "x_mm": 10, "y_mm": 10]]])
        let component = try XCTUnwrap(try result("get_component", ["refdes": "U1"]) as? JSONDictionary)
        XCTAssertEqual(component.dictionaryArray("pins").count, 2, "\(component)")
        let board = try XCTUnwrap(component["board"] as? JSONDictionary, "\(component)")
        XCTAssertEqual(board.string("package_id"), widget.package)
        XCTAssertEqual((component["physical_terminals"] as? [Any])?.count, 2, "\(component)")

        // Sent again, every item is found where it went, the same bytes.
        XCTAssertEqual(try poolWrite(widget.items), [])
    }

    func testApplysPoolItemsGoTheSameWay() throws {
        let widget = part("Widget-2")
        _ = try result("apply", ["ops": [["op": "ensure_component", "refdes": "U1", "part": widget.part]], "pool_items": widget.items])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try poolFile("parts/widget-2.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try poolFile("parts/cache/\(widget.part).json").path))
    }

    func testAnItemTheProjectHasIsWrittenOverWhereItIs() throws {
        // Imported, the resistor is a cached copy of Stock's, and an edit to
        // it stays one.
        _ = try result("import_pool_part", ["part": resistor.part])
        XCTAssertEqual(try poolWrite([["from": resistor.part, "patch": ["value": [false, "4k7"]]]]),
                       ["parts/cache/\(resistor.part).json"])

        // The project's own unit keeps its file when it is renamed.
        let widget = part("Widget-1")
        _ = try poolWrite(widget.items)
        XCTAssertEqual(try poolWrite([["from": widget.unit, "patch": ["name": "Gadget"]]]), ["units/widget-1.json"])
    }

    func testACopyOfAnAttachedPoolsItemIsCachedAndOneDerivedFromItIsTheProjects() throws {
        XCTAssertEqual(try poolWrite([["from": resistor.unit, "patch": ["manufacturer": "Stock"]]]),
                       ["units/cache/\(resistor.unit).json"])
        let derived = UUID().uuidString.lowercased()
        XCTAssertEqual(try poolWrite([["from": resistor.part, "uuid": derived, "patch": ["MPN": [false, "RC0603FR-074K7L"]]]]),
                       ["parts/rc0603fr-074k7l.json"])
    }

    func testANewItemKeepsClearOfTheFilesThereAndOfItsBatch() throws {
        _ = try poolWrite(part("Widget-1").items)
        // The same name in capitals is the same file on a Mac disk.
        let shouted = part("WIDGET-1")
        let twin = part("Widget-1")
        let written = try poolWrite(shouted.items + twin.items)
        XCTAssertEqual(written.filter { $0.hasPrefix("parts/") }, ["parts/widget-1-2.json", "parts/widget-1-3.json"])
        XCTAssertEqual(written.filter { $0.hasPrefix("packages/") },
                       ["packages/widget-1-pkg-2/package.json", "packages/widget-1-pkg-3/package.json"])
        // Each symbol beside its own unit.
        XCTAssertEqual(written.filter { $0.hasPrefix("symbols/") }, ["symbols/widget-1-2.json", "symbols/widget-1-3.json"])
    }
}
