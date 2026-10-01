import XCTest
@testable import HorizontalNative

final class HorizontalSchematicNetConnectivityTests: XCTestCase {
    private let block: JSONDictionary = ["nets": ["gnd": ["name": "GND"], "vref": ["name": "VREF 2V5"]]]

    private func sheet(_ a: String?, _ b: String?) -> JSONDictionary {
        var junctions: JSONDictionary = ["a": [:], "b": [:]]
        if let a { junctions["a"] = ["net": a] }
        if let b { junctions["b"] = ["net": b] }
        return ["junctions": junctions, "net_lines": ["wire": ["from": ["junc": "a"], "to": ["junc": "b"], "net": "gnd"]]]
    }

    func testConsistentEndpointNetsOverrideStaleWireNet() {
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet("vref", "vref"), block: block)
        XCTAssertEqual(connectivity.net(at: ["junc": "a"]), "vref")
        XCTAssertEqual(connectivity.net(at: ["junc": "b"]), "vref")
    }

    func testConflictingEndpointNetsAreNotHiddenByCachedWireNet() {
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet("vref", "gnd"), block: block)
        XCTAssertNil(connectivity.net(at: ["junc": "a"]))
        XCTAssertNil(connectivity.net(at: ["junc": "b"]))
    }

    func testUnanchoredWiresRetainCachedNetAsFallback() {
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet(nil, nil), block: block)
        XCTAssertEqual(connectivity.net(at: ["junc": "b"]), "gnd")
    }

    func testStandaloneSchematicCanResolveNetsWithoutABlock() {
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet("vref", nil), block: [:], requiresKnownNet: false)
        XCTAssertEqual(connectivity.net(at: ["junc": "b"]), "vref")
        XCTAssertNil(HorizontalSchematicNetConnectivity(sheet: sheet("vref", nil), block: [:]).net(at: ["junc": "b"]))
    }
}
