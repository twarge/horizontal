import XCTest
@testable import HorizontalNative

/// Horizon's wiring upkeep after an edit, as `HorizontalSchematicConnectivity`
/// applies it: wires of one net laid over each other heal, a wire ending on
/// another's side makes a T, a junction put on a pin connects it, and nets
/// that touch merge by Horizon's rules.
final class SchematicConnectivityTests: XCTestCase {
    private let grid = 1_250_000.0

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint { .init(x: x * grid, y: y * grid) }

    private func sheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: grid)
        sheet.netDetails = [
            "a": HorizontalNetDetails(id: "a", name: "A"),
            "b": HorizontalNetDetails(id: "b", name: "B"),
            "u": HorizontalNetDetails(id: "u", name: ""),
        ]
        return sheet
    }

    private func wire(_ id: String, _ from: String, _ fromPoint: HorizontalPoint, _ to: String, _ toPoint: HorizontalPoint, net: String?) -> HorizontalSegment {
        HorizontalSegment(id: id, from: fromPoint, to: toPoint, width: 0, layer: nil, netID: net,
                          schematicFrom: .junction(from), schematicTo: .junction(to))
    }

    private func addJunction(_ id: String, _ at: HorizontalPoint, net: String?, to sheet: inout HorizontalSchematicSheet) {
        sheet.junctions[id] = at
        if let net { sheet.junctionNetIDs[id] = net }
    }

    /// A resistor-like symbol with one pin `p` whose connection point is `at`.
    private func addSymbol(pinAt at: HorizontalPoint, connection: SchematicConnectionState?, to sheet: inout HorizontalSchematicSheet) {
        sheet.symbols.append(HorizontalPlacement(id: "sym", position: at, angle: 0, mirrored: false, label: "R1",
                                                 componentID: "comp", gateID: "gate"))
        sheet.symbolPins.append(HorizontalSegment(id: "sym/pin/p", from: at, to: at + HorizontalPoint(x: grid, y: 0),
                                                  width: 0, layer: nil, netID: connection?.netID))
        var connections = [String: SchematicConnectionState]()
        if let connection { connections["gate/p"] = connection }
        sheet.componentInfo["comp"] = SchematicComponentInfo(refdes: "R1", value: "", partID: nil, noPopulate: false,
                                                             gateSuffixes: [:], gateSymbolIDs: [:], altPins: [:],
                                                             connections: connections, details: nil)
    }

    private func spans(_ sheet: HorizontalSchematicSheet) -> Set<String> {
        Set(sheet.netLines.map { line -> String in
            let (a, b) = [line.from, line.to].map { "\(Int($0.x / grid)),\(Int($0.y / grid))" }.sorted().pairs
            return "\(a)-\(b)"
        })
    }

    // MARK: - Healing

    func testWiresOfOneNetLaidOverEachOtherHealIntoOne() {
        var sheet = sheet()
        addJunction("a0", point(0, 0), net: "a", to: &sheet)
        addJunction("a10", point(10, 0), net: "a", to: &sheet)
        addJunction("b5", point(5, 0), net: "a", to: &sheet)
        addJunction("b15", point(15, 0), net: "a", to: &sheet)
        sheet.netLines = [
            wire("left", "a0", point(0, 0), "a10", point(10, 0), net: "a"),
            wire("right", "b5", point(5, 0), "b15", point(15, 0), net: "a"),
        ]

        sheet.healNetLines()

        XCTAssertEqual(spans(sheet), ["0,0-15,0"])
        XCTAssertEqual(Set(sheet.junctions.keys), ["a0", "b15"])
    }

    func testAWireInsideAnotherOfItsNetDisappearsIntoIt() {
        var sheet = sheet()
        for (id, x) in [("j0", 0.0), ("j3", 3.0), ("j6", 6.0), ("j10", 10.0)] {
            addJunction(id, point(x, 0), net: "a", to: &sheet)
        }
        sheet.netLines = [
            wire("long", "j0", point(0, 0), "j10", point(10, 0), net: "a"),
            wire("short", "j6", point(6, 0), "j3", point(3, 0), net: "a"),
        ]

        sheet.healNetLines()

        XCTAssertEqual(spans(sheet), ["0,0-10,0"])
        XCTAssertEqual(sheet.netLines.map(\.id), ["long"])
        XCTAssertEqual(Set(sheet.junctions.keys), ["j0", "j10"])
    }

    func testAWireEndingOnAnotherOfItsNetMakesAT() {
        var sheet = sheet()
        addJunction("j0", point(0, 0), net: "a", to: &sheet)
        addJunction("j10", point(10, 0), net: "a", to: &sheet)
        addJunction("top", point(4, 5), net: "a", to: &sheet)
        addJunction("foot", point(4, 0), net: "a", to: &sheet)
        sheet.netLines = [
            wire("run", "j0", point(0, 0), "j10", point(10, 0), net: "a"),
            wire("stem", "top", point(4, 5), "foot", point(4, 0), net: "a"),
        ]

        sheet.healNetLines()

        XCTAssertEqual(spans(sheet), ["0,0-4,0", "10,0-4,0", "4,0-4,5"])
        let atFoot = sheet.netLines.filter { [$0.schematicFrom, $0.schematicTo].contains(.junction("foot")) }
        XCTAssertEqual(atFoot.count, 3, "three wires meet at the foot, which draws a dot")
    }

    func testWiresOfDifferentNetsAreLeftAlone() {
        var sheet = sheet()
        addJunction("j0", point(0, 0), net: "a", to: &sheet)
        addJunction("j10", point(10, 0), net: "a", to: &sheet)
        addJunction("top", point(4, 5), net: "b", to: &sheet)
        addJunction("foot", point(4, 0), net: "b", to: &sheet)
        addJunction("b6", point(6, 0), net: "b", to: &sheet)
        addJunction("b8", point(8, 0), net: "b", to: &sheet)
        sheet.netLines = [
            wire("run", "j0", point(0, 0), "j10", point(10, 0), net: "a"),
            wire("stem", "top", point(4, 5), "foot", point(4, 0), net: "b"),
            wire("over", "b6", point(6, 0), "b8", point(8, 0), net: "b"),
        ]

        XCTAssertTrue(sheet.healNetLines().isEmpty)
        XCTAssertEqual(sheet.netLines.map(\.id), ["run", "stem", "over"])
    }

    func testAPinOfTheNetPartwayAlongAWireSplitsItAtThePin() {
        var sheet = sheet()
        addJunction("j0", point(0, 0), net: "a", to: &sheet)
        addJunction("j10", point(10, 0), net: "a", to: &sheet)
        addSymbol(pinAt: point(5, 0), connection: .connected("a"), to: &sheet)
        sheet.netLines = [wire("run", "j0", point(0, 0), "j10", point(10, 0), net: "a")]

        sheet.healNetLines()

        XCTAssertEqual(spans(sheet), ["0,0-5,0", "10,0-5,0"])
        XCTAssertEqual(sheet.netLines.filter { [$0.schematicFrom, $0.schematicTo].contains(.pin("sym/p")) }.count, 2)
    }

    func testALabelHeldJunctionKeepsTheSplit() {
        var sheet = sheet()
        addJunction("j0", point(0, 0), net: "a", to: &sheet)
        addJunction("j10", point(10, 0), net: "a", to: &sheet)
        addJunction("label", point(5, 0), net: "a", to: &sheet)
        sheet.netLabels = [HorizontalSchematicNetLabel(id: "L", text: "A", position: point(5, 0), size: 1_500_000,
                                                       orientation: "right", netID: "a", junctionID: "label")]
        sheet.netLines = [wire("run", "j0", point(0, 0), "j10", point(10, 0), net: "a")]

        sheet.healNetLines()

        XCTAssertEqual(spans(sheet), ["0,0-5,0", "10,0-5,0"])
        XCTAssertNotNil(sheet.junctions["label"])
    }

    // MARK: - Connecting what an edit put down

    func testAJunctionMovedOntoAFreePinConnectsItToTheWiresNet() {
        var sheet = sheet()
        addSymbol(pinAt: point(5, 0), connection: nil, to: &sheet)
        addJunction("j0", point(0, 0), net: "a", to: &sheet)
        addJunction("end", point(5, 0), net: "a", to: &sheet)
        sheet.netLines = [wire("w", "j0", point(0, 0), "end", point(5, 0), net: "a")]
        let touched: Set<String> = [HorizontalCanvasModeSupport.pointKey(point(5, 0))]

        sheet.connectCoincident(at: touched)
        XCTAssertTrue(sheet.netConflicts(touching: touched).isEmpty)
        sheet.spreadNets(touching: touched)

        XCTAssertNil(sheet.junctions["end"], "the pin takes the junction's wire")
        XCTAssertEqual(sheet.netLines.first?.schematicTo, .pin("sym/p"))
        XCTAssertEqual(sheet.componentInfo["comp"]?.connections["gate/p"]?.netID, "a")
        XCTAssertEqual(sheet.symbolPins.first { $0.id == "sym/pin/p" }?.netID, "a")
        XCTAssertTrue(sheet.symbolPins.filter { $0.id.hasPrefix("sym/pin-connector/p") }.isEmpty,
                      "a connected pin draws no open box")
    }

    func testAWireWithNoNetReachingAFreePinGivesBothANewNet() {
        var sheet = sheet()
        addSymbol(pinAt: point(5, 0), connection: nil, to: &sheet)
        addJunction("j0", point(0, 0), net: nil, to: &sheet)
        sheet.netLines = [HorizontalSegment(id: "w", from: point(0, 0), to: point(5, 0), width: 0, layer: nil,
                                            schematicFrom: .junction("j0"), schematicTo: .pin("sym/p"))]
        let touched: Set<String> = [HorizontalCanvasModeSupport.pointKey(point(5, 0))]

        sheet.spreadNets(touching: touched)

        let netID = try? XCTUnwrap(sheet.netLines.first?.netID)
        XCTAssertNotNil(netID)
        XCTAssertEqual(sheet.netDetails[netID ?? ""]?.name, "")
        XCTAssertEqual(sheet.componentInfo["comp"]?.connections["gate/p"]?.netID, netID)
        XCTAssertEqual(sheet.junctionNetIDs["j0"], netID)
    }

    func testANoConnectPinIsNotConnected() {
        var sheet = sheet()
        addSymbol(pinAt: point(5, 0), connection: .notConnected, to: &sheet)
        addJunction("j0", point(0, 0), net: "a", to: &sheet)
        addJunction("end", point(5, 0), net: "a", to: &sheet)
        sheet.netLines = [wire("w", "j0", point(0, 0), "end", point(5, 0), net: "a")]
        let touched: Set<String> = [HorizontalCanvasModeSupport.pointKey(point(5, 0))]

        sheet.connectCoincident(at: touched)
        sheet.spreadNets(touching: touched)

        XCTAssertNotNil(sheet.junctions["end"])
        XCTAssertNil(sheet.componentInfo["comp"]?.connections["gate/p"]?.netID)
    }

    func testJunctionsOfTwoNetsOnOnePointAreAConflict() {
        var sheet = sheet()
        addJunction("a0", point(0, 0), net: "a", to: &sheet)
        addJunction("a5", point(5, 0), net: "a", to: &sheet)
        addJunction("b5", point(5, 0), net: "b", to: &sheet)
        addJunction("b9", point(5, 4), net: "b", to: &sheet)
        sheet.netLines = [
            wire("wa", "a0", point(0, 0), "a5", point(5, 0), net: "a"),
            wire("wb", "b5", point(5, 0), "b9", point(5, 4), net: "b"),
        ]
        let touched: Set<String> = [HorizontalCanvasModeSupport.pointKey(point(5, 0))]

        sheet.connectCoincident(at: touched)

        XCTAssertEqual(sheet.junctions.count, 3)
        XCTAssertEqual(sheet.netConflicts(touching: touched), [["a", "b"]])
        XCTAssertTrue(sheet.netConflicts(touching: [HorizontalCanvasModeSupport.pointKey(point(40, 40))]).isEmpty)
    }

    // MARK: - Deleting a wire whose junction went

    /// A wire that ended on a junction a pin was later dropped on: the
    /// junction went, and the wire's stored end still names it.
    private func wireToAPinThatTookItsJunction() -> HorizontalSchematicSheet {
        var sheet = sheet()
        addSymbol(pinAt: point(5, 0), connection: .connected("a"), to: &sheet)
        addJunction("j0", point(0, 0), net: "a", to: &sheet)
        sheet.netLines = [wire("w", "j0", point(0, 0), "gone", point(5, 0), net: "a")]
        return sheet
    }

    func testAPinStillWiredThroughAStaleJunctionEndRaisesNoWarning() {
        let sheet = wireToAPinThatTookItsJunction()
        let messages = HorizontalSchematicWarnings.evaluate(sheet).flatMap(\.messages)
        XCTAssertFalse(messages.contains { $0.hasPrefix("Pin connected to net") }, "\(messages)")
    }

    func testDeletingTheWireTakesThePinOffTheNet() {
        var sheet = wireToAPinThatTookItsJunction()
        let before = sheet.netLines
        sheet.netLines.removeAll()
        sheet.disconnectPinsLeftWithoutWires(netLinesBefore: before)

        XCTAssertNil(sheet.componentInfo["comp"]?.connections["gate/p"])
        XCTAssertEqual(sheet.removedConnections, ["comp": ["gate/p"]])
        XCTAssertNil(sheet.symbolPins.first { $0.id == "sym/pin/p" }?.netID)
        let messages = HorizontalSchematicWarnings.evaluate(sheet).flatMap(\.messages)
        XCTAssertFalse(messages.contains { $0.hasPrefix("Pin connected to net") }, "\(messages)")
    }

    // MARK: - Merging nets

    func testMergeVerdictsFollowHorizon() {
        var sheet = sheet()
        sheet.netDetails["gnd"] = HorizontalNetDetails(id: "gnd", name: "GND", isPower: true)
        sheet.netDetails["vcc"] = HorizontalNetDetails(id: "vcc", name: "VCC", isPower: true)
        sheet.netDetails["port"] = HorizontalNetDetails(id: "port", name: "IN", isPort: true)
        sheet.netDetails["n"] = HorizontalNetDetails(id: "n", name: "")
        sheet.busDetails = [HorizontalBusDetails(id: "bus", name: "D", members: [.init(id: "m", name: "D0", netID: "d0")])]
        sheet.netDetails["d0"] = HorizontalNetDetails(id: "d0", name: "D0")

        XCTAssertEqual(sheet.netMergeVerdict("gnd", into: "u"), .merge(from: "u", into: "gnd"))
        XCTAssertEqual(sheet.netMergeVerdict("gnd", into: "vcc"), .refuse("Can't merge power nets"))
        XCTAssertEqual(sheet.netMergeVerdict("port", into: "a"), .merge(from: "a", into: "port"))
        XCTAssertEqual(sheet.netMergeVerdict("a", into: "b"), .ask("a", "b"))
        XCTAssertEqual(sheet.netMergeVerdict("a", into: "u"), .merge(from: "u", into: "a"))
        XCTAssertEqual(sheet.netMergeVerdict("u", into: "a"), .merge(from: "u", into: "a"))
        XCTAssertEqual(sheet.netMergeVerdict("d0", into: "a"), .merge(from: "a", into: "d0"))
        XCTAssertEqual(sheet.netMergeVerdict("d0", into: "gnd"), .refuse("Can't merge a power net and a bussed net"))
        XCTAssertEqual(sheet.netMergeVerdict("u", into: "n", preferring: ["n"]), .merge(from: "n", into: "u"),
                       "a net the edit made gives way to one that exists")
    }

    func testMergingANetMovesEverythingOnItAndRemovesIt() {
        var sheet = sheet()
        addSymbol(pinAt: point(5, 0), connection: .connected("b"), to: &sheet)
        addJunction("j", point(0, 0), net: "b", to: &sheet)
        sheet.netLines = [wire("w", "j", point(0, 0), "j", point(5, 0), net: "b")]
        sheet.netLabels = [HorizontalSchematicNetLabel(id: "L", text: "B", position: point(0, 0), size: 1_500_000,
                                                       orientation: "right", netID: "b", junctionID: "j")]

        sheet.mergeNet("b", into: "a")

        XCTAssertEqual(sheet.netLines.first?.netID, "a")
        XCTAssertEqual(sheet.junctionNetIDs["j"], "a")
        XCTAssertEqual(sheet.netLabels.first?.netID, "a")
        XCTAssertEqual(sheet.netLabels.first?.text, "A")
        XCTAssertEqual(sheet.componentInfo["comp"]?.connections["gate/p"]?.netID, "a")
        XCTAssertEqual(sheet.symbolPins.first?.netID, "a")
        XCTAssertNil(sheet.netDetails["b"])
        XCTAssertEqual(sheet.removedNetIDs, ["b"])
    }

    // MARK: - What an edit touched

    func testTouchedPointsAreWhereTheWiringChanged() {
        var original = sheet()
        addJunction("j0", point(0, 0), net: "a", to: &original)
        addJunction("j1", point(4, 0), net: "a", to: &original)
        addJunction("far", point(20, 20), net: "a", to: &original)
        original.netLines = [wire("w", "j0", point(0, 0), "j1", point(4, 0), net: "a")]
        var edited = original
        edited.junctions["j1"] = point(4, 3)
        edited.netLines[0].to = point(4, 3)

        let touched = edited.touchedPointKeys(since: original)

        XCTAssertEqual(touched, [HorizontalCanvasModeSupport.pointKey(point(0, 0)), HorizontalCanvasModeSupport.pointKey(point(4, 3))])
    }
}

private extension Array where Element == String {
    var pairs: (String, String) { (self[0], self[1]) }
}
