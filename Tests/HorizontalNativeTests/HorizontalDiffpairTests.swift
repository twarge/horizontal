import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Differential pairs as Horizon keeps them: the block file names a pair on
/// its primary alone (Net::serialize), the secondary learns its partner as
/// the block loads (Block::update_diffpairs), and Set and Clear Diff Pair
/// write that and nothing else, through the edit vocabulary the inspectors
/// and the MCP tools share.
final class HorizontalDiffpairTests: XCTestCase {
    private let tx = "11111111-1111-4111-8111-111111111111"
    private let txn = "22222222-2222-4222-8222-222222222222"
    private let rx = "33333333-3333-4333-8333-333333333333"
    private let rxn = "44444444-4444-4444-8444-444444444444"

    private func nets(_ entries: [(String, String, String?)]) -> JSONDictionary {
        entries.reduce(into: JSONDictionary()) { result, entry in
            var net: JSONDictionary = ["name": entry.1, "is_power": false]
            if let partner = entry.2 { net["diffpair"] = partner }
            result[entry.0] = net
        }
    }

    // MARK: - The file

    func testThePrimaryNamesThePairAndTheSecondaryLearnsIt() {
        let block = nets([(tx, "TX+", txn), (txn, "TX-", nil),
                          (rx, "RX+", "00000000-0000-0000-0000-000000000000"),
                          (rxn, "RX-", "55555555-5555-4555-8555-555555555555")])
        let pairings = HorizontalDiffpairs.resolve(block.compactMapValues { $0 as? JSONDictionary })
        XCTAssertEqual(pairings[tx], HorizontalDiffpairs.Pairing(partnerID: txn, isPrimary: true))
        XCTAssertEqual(pairings[txn], HorizontalDiffpairs.Pairing(partnerID: tx, isPrimary: false))
        // The null uuid and a net the block lacks pair nothing, as Horizon's
        // Net reads them.
        XCTAssertNil(pairings[rx])
        XCTAssertNil(pairings[rxn])
        XCTAssertEqual(pairings.count, 2)
    }

    func testDetailsCarryEachNetsPartner() {
        let block = nets([(tx, "TX+", txn.uppercased()), (txn, "TX-", nil), (rx, "RX+", nil)])
        var details = [tx: HorizontalNetDetails(id: tx, name: "TX+"), txn: HorizontalNetDetails(id: txn, name: "TX-"),
                       rx: HorizontalNetDetails(id: rx, name: "RX+")]
        HorizontalDiffpairs.annotate(&details, nets: block.compactMapValues { $0 as? JSONDictionary })
        XCTAssertEqual(details[tx]?.diffpairID, txn)
        XCTAssertEqual(details[tx]?.isDiffpairPrimary, true)
        XCTAssertEqual(details[txn]?.diffpairID, tx)
        XCTAssertEqual(details[txn]?.isDiffpairPrimary, false)
        XCTAssertNil(details[rx]?.diffpairID)
        XCTAssertEqual(HorizontalDiffpairs.pairedNetIDs(details), [tx, txn])
        XCTAssertEqual(HorizontalDiffpairProperty.summary(for: tx, in: details), "Pri: TX-")
        XCTAssertEqual(HorizontalDiffpairProperty.summary(for: txn, in: details), "Sec: TX+")
        XCTAssertEqual(HorizontalDiffpairProperty.summary(for: rx, in: details), "None")
    }

    func testPairWritesThePrimaryAloneAndRefusesAThirdNet() throws {
        var block = nets([(tx, "TX+", nil), (txn, "TX-", nil), (rx, "RX+", nil)])
        XCTAssertTrue(try HorizontalDiffpairs.pair(tx, with: txn, in: &block))
        XCTAssertEqual((block[tx] as? JSONDictionary)?.string("diffpair"), txn)
        XCTAssertNil((block[txn] as? JSONDictionary)?["diffpair"])
        XCTAssertNil((block[tx] as? JSONDictionary)?["diffpair_primary"], "Horizon writes no such key")
        // Again is nothing to do.
        XCTAssertFalse(try HorizontalDiffpairs.pair(tx, with: txn, in: &block))

        XCTAssertThrowsError(try HorizontalDiffpairs.pair(rx, with: txn, in: &block)) { error in
            XCTAssertEqual(error as? HorizontalDiffpairs.PairingError, .alreadyPaired(net: "TX-", partner: "TX+"))
        }
        XCTAssertThrowsError(try HorizontalDiffpairs.pair(tx, with: rx, in: &block))
        XCTAssertThrowsError(try HorizontalDiffpairs.pair(rx, with: rx, in: &block)) { error in
            XCTAssertEqual(error as? HorizontalDiffpairs.PairingError, .sameNet(rx))
        }

        // The other way round swaps the roles.
        XCTAssertTrue(try HorizontalDiffpairs.pair(txn, with: tx, in: &block))
        XCTAssertEqual((block[txn] as? JSONDictionary)?.string("diffpair"), tx)
        XCTAssertNil((block[tx] as? JSONDictionary)?["diffpair"])
    }

    func testUnpairTakesTheNetOutFromEitherSide() {
        var block = nets([(tx, "TX+", txn), (txn, "TX-", nil), (rx, "RX+", nil)])
        XCTAssertEqual(HorizontalDiffpairs.unpair(txn, in: &block), tx)
        XCTAssertNil((block[tx] as? JSONDictionary)?["diffpair"])
        XCTAssertNil(HorizontalDiffpairs.unpair(rx, in: &block), "a net in no pair is left as it is")
        XCTAssertTrue(HorizontalDiffpairs.resolve(block.compactMapValues { $0 as? JSONDictionary }).isEmpty)

        var stale = nets([(tx, "TX+", txn), (txn, "TX-", nil)])
        HorizontalDiffpairs.dropReferences(to: [txn.uppercased()], in: &stale)
        XCTAssertNil((stale[tx] as? JSONDictionary)?["diffpair"])
    }

    // MARK: - The inspector

    func testTheInspectorOffersFreeNetsAndMakesTheOps() throws {
        var details = [tx: HorizontalNetDetails(id: tx, name: "TX+"), txn: HorizontalNetDetails(id: txn, name: "TX-"),
                       rx: HorizontalNetDetails(id: rx, name: "RX+"), rxn: HorizontalNetDetails(id: rxn, name: "GND", isPower: true)]
        let property = try XCTUnwrap(HorizontalDiffpairProperty.property(for: tx, in: details, editable: true))
        guard case .choice(let options) = property.editor else { return XCTFail("\(property.editor)") }
        XCTAssertEqual(options.map(\.title), ["None", "RX+", "TX-"], "named, not power, not itself")
        XCTAssertEqual(property.value, .choice(HorizontalDiffpairProperty.noneID))

        let set = try XCTUnwrap(HorizontalDiffpairProperty.operations(for: tx, choice: txn, in: details))
        XCTAssertEqual(set.actionName, "Set Diff Pair")
        XCTAssertEqual(set.ops.map { $0.string("op") }, ["set_diffpair"])
        XCTAssertEqual(set.ops.first?.string("partner"), txn)
        XCTAssertNil(HorizontalDiffpairProperty.operations(for: tx, choice: HorizontalDiffpairProperty.noneID, in: details))

        details[tx]?.diffpairID = txn
        details[tx]?.isDiffpairPrimary = true
        details[txn]?.diffpairID = tx
        let paired = try XCTUnwrap(HorizontalDiffpairProperty.property(for: txn, in: details, editable: true))
        guard case .choice(let pairedOptions) = paired.editor else { return XCTFail() }
        XCTAssertEqual(pairedOptions.map(\.title), ["None", "Sec: TX+", "RX+"], "the partner first, nets in a pair left out")
        XCTAssertEqual(paired.value, .choice(tx))
        XCTAssertEqual(HorizontalDiffpairProperty.operations(for: txn, choice: "none", in: details)?.ops.map { $0.string("op") },
                       ["clear_diffpair"])
        XCTAssertEqual(HorizontalDiffpairProperty.operations(for: txn, choice: rx, in: details)?.ops.map { $0.string("op") },
                       ["clear_diffpair", "set_diffpair"], "another partner: out of the old pair first")
        XCTAssertNil(HorizontalDiffpairProperty.operations(for: txn, choice: tx, in: details))
        XCTAssertEqual(HorizontalDiffpairProperty.property(for: txn, in: details, editable: false)?.value, .readOnly("Sec: TX+"))
        XCTAssertNil(HorizontalDiffpairProperty.property(for: rxn, in: details, editable: true), "a power net has no pair")

        // The menu's two-net Set Diff Pair: TX+ sorts first, so it is the primary.
        details[tx]?.diffpairID = nil
        details[txn]?.diffpairID = nil
        let pairing = try XCTUnwrap(HorizontalDiffpairProperty.pairing(of: [txn, tx], in: details))
        XCTAssertEqual(pairing.ops.first?.string("net"), tx)
        XCTAssertEqual(pairing.ops.first?.string("partner"), txn)
        XCTAssertNil(HorizontalDiffpairProperty.pairing(of: [tx], in: details))
        XCTAssertNil(HorizontalDiffpairProperty.clearing(of: [tx], in: details))
    }

    // MARK: - Hierarchy and paste

    func testAnInstancesPairIsItsOwnInTheFlattenedBlock() throws {
        let top = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", sub = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let first = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", second = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let topBlock: JSONDictionary = [
            "uuid": top, "nets": nets([(rx, "RX+", rxn), (rxn, "RX-", nil)]), "components": JSONDictionary(),
            "block_instances": [first: ["block": sub, "refdes": "I1", "connections": JSONDictionary()],
                                second: ["block": sub, "refdes": "I2", "connections": JSONDictionary()]]
        ]
        let subBlock: JSONDictionary = ["uuid": sub, "nets": nets([(tx, "D+", txn), (txn, "D-", nil)]), "components": JSONDictionary()]
        let flat = HorizontalBlockFlattener.flatten(top: topBlock, blocks: [top: topBlock, sub: subBlock])
        let flatNets = flat.json.dictionaryMap("nets")
        for instance in [first, second] {
            let primary = HorizontalBlockFlattener.flattenedID([instance, tx])
            let secondary = HorizontalBlockFlattener.flattenedID([instance, txn])
            XCTAssertEqual(flatNets[primary]?.string("diffpair"), secondary)
            XCTAssertNil(flatNets[secondary]?["diffpair"])
        }
        XCTAssertEqual(flatNets[rx]?.string("diffpair"), rxn, "the top block's own pair stays")
        XCTAssertFalse(flatNets.values.contains { $0["diffpair_primary"] != nil }, "Horizon's file has no such key")
        XCTAssertEqual(HorizontalDiffpairs.resolve(flatNets).count, 6)
    }

    // MARK: - Through the editor and the file

    func testSetAndClearDiffPairRoundTripThroughTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-diffpair-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Pairs.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        let session = DispatchClient(path: packageURL.path)
        try session.open()
        defer { session.close() }

        _ = try session.apply([["op": "ensure_net", "name": "TX+"], ["op": "ensure_net", "name": "TX-"],
                               ["op": "ensure_net", "name": "RX+"]])
        let unpaired = try HorizontalProject.load(from: packageURL)
        let blockURL = unpaired.baseURL.appendingPathComponent(
            try XCTUnwrap(unpaired.blocks.first(where: \.isTop)?.blockFilename ?? unpaired.blockFilename))
        let before = try Data(contentsOf: blockURL)
        let set = try session.apply([["op": "set_diffpair", "net": "TX+", "partner": "TX-"]])
        let change = try XCTUnwrap((set["changes"] as? [JSONDictionary])?.first)
        XCTAssertEqual(change["changed"] as? Bool, true)

        // In the file: on the primary, and nowhere else.
        let project = try HorizontalProject.load(from: packageURL)
        let blockFile = try XCTUnwrap(project.blocks.first(where: \.isTop)?.blockFilename ?? project.blockFilename)
        let block = try JSONHelper.loadDictionary(from: project.baseURL.appendingPathComponent(blockFile))
        let byName = block.dictionaryMap("nets").reduce(into: [String: (String, JSONDictionary)]()) { result, net in
            result[net.value.string("name") ?? ""] = (net.key.lowercased(), net.value)
        }
        let (txID, txJSON) = try XCTUnwrap(byName["TX+"])
        let (txnID, txnJSON) = try XCTUnwrap(byName["TX-"])
        XCTAssertEqual(txJSON.string("diffpair"), txnID)
        XCTAssertNil(txnJSON["diffpair"])
        XCTAssertFalse(block.dictionaryMap("nets").values.contains { $0["diffpair_primary"] != nil })

        // Loaded again, both sides know it: the schematic, the board and the reads.
        XCTAssertEqual(project.schematic?.netDetails[txnID]?.diffpairID, txID)
        XCTAssertEqual(project.schematic?.netDetails[txID]?.isDiffpairPrimary, true)
        XCTAssertEqual(project.board?.netDetails[txnID]?.diffpairID, txID)
        let secondary = try XCTUnwrap(try session.result("get_net", ["name": "TX-"]) as? JSONDictionary)
        XCTAssertEqual(secondary.dictionary("diffpair")?.string("net"), "TX+")
        XCTAssertEqual(secondary.dictionary("diffpair")?.bool("primary"), false)
        XCTAssertNotNil(secondary["routed_length_mm"])
        let listed = try XCTUnwrap(try session.result("list_nets") as? [JSONDictionary])
        XCTAssertEqual(listed.first { $0.string("name") == "TX+" }?.dictionary("diffpair")?.string("id"), txnID)
        XCTAssertNil(listed.first { $0.string("name") == "RX+" }?["diffpair"])

        // A third net can't join; the pair cleared from its secondary is gone.
        XCTAssertNotNil(try session.call("apply", ["ops": [["op": "set_diffpair", "net": "RX+", "partner": "TX-"]]])["error"])
        _ = try session.apply([["op": "clear_diffpair", "net": "TX-"]])
        let cleared = try JSONHelper.loadDictionary(from: project.baseURL.appendingPathComponent(blockFile))
        XCTAssertFalse(cleared.dictionaryMap("nets").values.contains { $0["diffpair"] != nil })
        XCTAssertNil((try session.result("get_net", ["name": "TX+"]) as? JSONDictionary)?["diffpair"])
        // Set and cleared, the block is the bytes it was: nothing else moved.
        XCTAssertEqual(try Data(contentsOf: blockURL), before)
    }
}

/// The JSON-RPC dispatcher as the MCP server drives it, for one project.
private final class DispatchClient {
    let path: String
    private var handle = 0

    init(path: String) {
        self.path = path
    }

    func open() throws {
        let summary = try XCTUnwrap(try result("open_project", ["path": path]) as? JSONDictionary)
        handle = try XCTUnwrap(summary["handle"] as? Int)
    }

    func close() {
        _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#)
    }

    func call(_ method: String, _ params: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = params
        if method != "open_project" {
            params["handle"] = handle
        }
        if method == "apply" {
            let handle = self.handle
            params["expected_revision"] = try HorizontalDispatchSession.shared.perform { try $0.entry(handle: handle).revision }
            params["operation_id"] = UUID().uuidString
        }
        let request: JSONDictionary = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let response = HorizontalDispatch.call(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? JSONDictionary)
    }

    func result(_ method: String, _ params: JSONDictionary = [:]) throws -> Any {
        let response = try call(method, params)
        if let error = response["error"] {
            XCTFail("\(method) failed: \(error)")
        }
        return try XCTUnwrap(response["result"])
    }

    func apply(_ ops: [JSONDictionary]) throws -> JSONDictionary {
        try XCTUnwrap(try result("apply", ["ops": ops]) as? JSONDictionary)
    }
}
