import Foundation
import XCTest
@testable import HorizontalNative

final class SchematicPlacementTests: XCTestCase {
    func testMirroredVerticalResistorConnectsAtTheCorrectEnds() throws {
        // Reduced from the reported document's R1, including its 270m text view.
        let sheet = try fixture(angle: 49_152, mirrored: true, resistor: true)
        let upper = try XCTUnwrap(sheet.symbolPins.first { $0.id == "symbol/pin/a" })
        let lower = try XCTUnwrap(sheet.symbolPins.first { $0.id == "symbol/pin/b" })
        XCTAssertEqual(upper.from, HorizontalPoint(x: 0, y: 3_750_000))
        XCTAssertEqual(upper.to, HorizontalPoint(x: 0, y: 2_500_000))
        XCTAssertEqual(lower.from, HorizontalPoint(x: 0, y: -3_750_000))
        XCTAssertEqual(lower.to, HorizontalPoint(x: 0, y: -2_500_000))
        let upperWire = try XCTUnwrap(sheet.netLines.first { $0.id == "upper-wire" })
        let lowerWire = try XCTUnwrap(sheet.netLines.first { $0.id == "lower-wire" })
        XCTAssertEqual(upperWire.from, upper.from)
        XCTAssertEqual(upperWire.to, HorizontalPoint(x: 0, y: 5_000_000))
        XCTAssertEqual(lowerWire.from, lower.from)
        XCTAssertEqual(lowerWire.to, HorizontalPoint(x: 0, y: -5_000_000))
        XCTAssertEqual(upperWire.length, 1_250_000)
        XCTAssertEqual(lowerWire.length, 1_250_000)
        XCTAssertEqual(sheet.symbolTexts.first { $0.text == "R1" }?.position,
                       HorizontalPoint(x: 2_500_000, y: 1_250_000))
        XCTAssertEqual(sheet.symbolTexts.first { $0.text == "100 kΩ" }?.position,
                       HorizontalPoint(x: 2_500_000, y: -1_250_000))
    }

    func testPinNamesStayInsideAndNCOutsideAtEveryOrientation() throws {
        // The AD5144 potentiometer has left/right pins and a perpendicular wiper.
        // Expected coordinates follow Horizon's rotate-then-mirror file format.
        let expected: [(Int, HorizontalPoint, HorizontalPoint, HorizontalPoint)] = [
            (0, .init(x: -5_000_000, y: 0), .init(x: 0, y: -3_750_000), .init(x: 2_000_000, y: 1_000_000)),
            (16_384, .init(x: 0, y: -5_000_000), .init(x: 3_750_000, y: 0), .init(x: -1_000_000, y: 2_000_000)),
            (32_768, .init(x: 5_000_000, y: 0), .init(x: 0, y: 3_750_000), .init(x: -2_000_000, y: -1_000_000)),
            (49_152, .init(x: 0, y: 5_000_000), .init(x: -3_750_000, y: 0), .init(x: 1_000_000, y: -2_000_000)),
        ]
        for (angle, left, wiper, outline) in expected {
            for mirrored in [false, true] {
                let sheet = try fixture(angle: angle, mirrored: mirrored)
                func mirror(_ p: HorizontalPoint) -> HorizontalPoint {
                    .init(x: mirrored ? -p.x : p.x, y: p.y)
                }
                let positions = ["a": mirror(left), "b": mirror(.init(x: -left.x, y: -left.y)), "c": mirror(wiper)]
                for (id, expectedPosition) in positions {
                    let pin = try XCTUnwrap(sheet.symbolPins.first { $0.id == "symbol/pin/\(id)" })
                    let name = try XCTUnwrap(sheet.symbolTexts.first { $0.id == "symbol/pin-name/\(id)" })
                    let nc = try XCTUnwrap(sheet.symbolTexts.first { $0.id == "symbol/pin-connector-text/\(id)" })
                    XCTAssertEqual(pin.from, expectedPosition, "\(angle), mirror \(mirrored), pin \(id)")
                    let inward = pin.to - pin.from
                    func alongPin(_ point: HorizontalPoint) -> Double {
                        let offset = point - pin.from
                        return offset.x * inward.x + offset.y * inward.y
                    }
                    XCTAssertGreaterThan(alongPin(name.position), 0, "Pin name belongs inside the symbol")
                    XCTAssertLessThan(alongPin(nc.position), 0, "NC belongs outside the symbol")
                    XCTAssertEqual(name.text, id.uppercased())
                    XCTAssertEqual(nc.text, "NC")
                }
                XCTAssertEqual(sheet.symbolLines.first { $0.id == "symbol/line/outline" }?.to, mirror(outline))
                XCTAssertTrue(try XCTUnwrap(sheet.symbolPolygons.first).vertices.contains(mirror(outline)))
                XCTAssertEqual(sheet.symbolLines.first { $0.id == "symbol/arc/curve/0" }?.from, mirror(outline))
                XCTAssertEqual(sheet.symbols.first?.angle, angle, "Keep the stored file angle")
                XCTAssertEqual(sheet.symbols.first?.mirrored, mirrored)
            }
        }
    }

    private func fixture(angle: Int, mirrored: Bool, resistor: Bool = false) throws -> HorizontalSchematicSheet {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schematic-placement-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func write(_ json: JSONDictionary, _ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
            return url
        }
        func pin(_ position: [Int], _ orientation: String) -> JSONDictionary {
            ["position": position, "orientation": orientation, "length": resistor ? 1_250_000 : 2_500_000,
             "name_visible": !resistor, "pad_visible": false, "name_orientation": "in_line"]
        }
        let reach = resistor ? 3_750_000 : 5_000_000
        var pins: [String: JSONDictionary] = ["a": pin([-reach, 0], "left"), "b": pin([reach, 0], "right")]
        if !resistor { pins["c"] = pin([0, -3_750_000], "down") }
        let symbol: JSONDictionary = [
            "uuid": "part-symbol", "unit": "unit", "pins": pins,
            "junctions": ["origin": ["position": [0, 0]], "corner": ["position": [2_000_000, 1_000_000]],
                          "end": ["position": [-1_000_000, 2_000_000]]],
            "lines": ["outline": ["from": "origin", "to": "corner", "width": 0]],
            "arcs": ["curve": ["from": "corner", "to": "end", "center": "origin", "width": 0]],
            "polygons": ["body": ["vertices": [["position": [0, 0]], ["position": [2_000_000, 1_000_000]], ["position": [0, 2_000_000]]]]],
            "texts": [
                "refdes": ["text": "$REFDES", "size": 1_500_000, "placement": ["shift": [0, 0]]],
                "value": ["text": "$VALUE", "size": 1_500_000, "placement": ["shift": [0, 0]]],
            ],
            "text_placements": ["270m": [
                "refdes": ["shift": [-1_250_000, -2_500_000], "angle": 16_384, "mirror": true],
                "value": ["shift": [1_250_000, -2_500_000], "angle": 16_384, "mirror": true],
            ]],
        ]
        _ = try write(symbol, "pool/symbols/cache/part-symbol.json")
        _ = try write(["pins": ["a": ["primary_name": "A"], "b": ["primary_name": "B"], "c": ["primary_name": "C"]]],
                      "pool/units/cache/unit.json")
        let connections: JSONDictionary = resistor
            ? ["gate/a": ["net": "upper-net"], "gate/b": ["net": "lower-net"]]
            : ["gate/a": [:], "gate/b": [:], "gate/c": [:]]
        let block = try write(["components": ["component": ["refdes": "R1", "value": "100 kΩ", "connections": connections]]], "block.json")
        var sheet: JSONDictionary = ["name": "Sheet", "index": 1, "symbols": ["symbol": [
            "symbol": "part-symbol", "component": "component", "gate": "gate",
            "placement": ["shift": [0, 0], "angle": angle, "mirror": mirrored],
        ]]]
        if resistor {
            sheet["junctions"] = ["upper": ["position": [0, 5_000_000], "net": "upper-net"],
                                  "lower": ["position": [0, -5_000_000], "net": "lower-net"]]
            sheet["net_lines"] = [
                "upper-wire": ["from": ["pin": "symbol/a"], "to": ["junc": "upper"]],
                "lower-wire": ["from": ["pin": "symbol/b"], "to": ["junc": "lower"]],
            ]
        }
        let schematic = try write(["sheets": ["sheet": sheet]], "schematic.json")
        var diagnostics: [HorizontalDiagnostic] = []
        return try XCTUnwrap(HorizontalSchematic.load(from: schematic, blockURL: block, poolURL: root.appendingPathComponent("pool"),
                                                     diagnostics: &diagnostics).sheets.first)
    }
}
