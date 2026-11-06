import XCTest
@testable import HorizontalNative

/// A sheet's nets by what its wires join. Horizon stores no net on a junction
/// or wire, so one written there is taken only where the MCP editor asks
/// (`cachedNets`), for the batch that wrote it.
final class HorizontalSchematicNetConnectivityTests: XCTestCase {
    private let block: JSONDictionary = ["nets": ["gnd": ["name": "GND"], "vref": ["name": "VREF 2V5"]]]

    private func sheet(_ a: String?, _ b: String?) -> JSONDictionary {
        var junctions: JSONDictionary = ["a": [:], "b": [:]]
        if let a { junctions["a"] = ["net": a] }
        if let b { junctions["b"] = ["net": b] }
        return ["junctions": junctions, "net_lines": ["wire": ["from": ["junc": "a"], "to": ["junc": "b"], "net": "gnd"]]]
    }

    func testConsistentEndpointNetsOverrideStaleWireNet() {
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet("vref", "vref"), block: block, cachedNets: true)
        XCTAssertEqual(connectivity.net(at: ["junc": "a"]), "vref")
        XCTAssertEqual(connectivity.net(at: ["junc": "b"]), "vref")
    }

    func testConflictingEndpointNetsAreNotHiddenByCachedWireNet() {
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet("vref", "gnd"), block: block, cachedNets: true)
        XCTAssertNil(connectivity.net(at: ["junc": "a"]))
        XCTAssertNil(connectivity.net(at: ["junc": "b"]))
    }

    func testUnanchoredWiresRetainCachedNetAsFallback() {
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet(nil, nil), block: block, cachedNets: true)
        XCTAssertEqual(connectivity.net(at: ["junc": "b"]), "gnd")
    }

    func testStandaloneSchematicCanResolveNetsWithoutABlock() {
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet("vref", nil), block: [:], requiresKnownNet: false, cachedNets: true)
        XCTAssertEqual(connectivity.net(at: ["junc": "b"]), "vref")
        XCTAssertNil(HorizontalSchematicNetConnectivity(sheet: sheet("vref", nil), block: [:], cachedNets: true).net(at: ["junc": "b"]))
    }

    /// Read as Horizon reads a sheet, a net written on a junction or wire is
    /// nothing: wiring joined to no pin, label, power symbol, port or bus
    /// ripper has no net, and a power symbol gives its wiring its own.
    func testNetsWrittenOnJunctionsAndWiresAreIgnoredByDefault() {
        let floating = HorizontalSchematicNetConnectivity(sheet: sheet("vref", "vref"), block: block)
        XCTAssertNil(floating.net(at: ["junc": "a"]))
        XCTAssertNil(floating.net(at: ["junc": "b"]))

        var grounded = sheet("vref", "vref")
        grounded["power_symbols"] = ["p": ["junction": "a", "net": "gnd"]]
        let connectivity = HorizontalSchematicNetConnectivity(sheet: grounded, block: block)
        XCTAssertEqual(connectivity.net(at: ["junc": "a"]), "gnd")
        XCTAssertEqual(connectivity.net(at: ["junc": "b"]), "gnd")
    }
}
