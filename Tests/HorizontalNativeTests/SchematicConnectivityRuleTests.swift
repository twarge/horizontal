import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The schematic's Connectivity rule, as Horizon's
/// `SchematicRules::check_connectivity` runs it: a net only one pin is on, a
/// net only one of whose segments has a label, a pin on no net and not marked
/// no-connect, each where the schematic draws it. Two-pin resistors on the
/// template project's sheet, wired through the same ops an automation client
/// uses.
final class SchematicConnectivityRuleTests: XCTestCase {
    private var archive: HorizontalProjectArchive!
    private var project: HorizontalProject!
    private var part = ""
    private var gate = ""

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schematic-connectivity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)

        let poolURL = url.appendingPathComponent("pool")
        var unit = HorizontalPoolItemFactory.newUnit()
        let first = HorizontalPoolItemFactory.newUUID(), second = HorizontalPoolItemFactory.newUUID()
        unit.pins = [first: HorizontalUnitPin(id: first, primaryName: "1"), second: HorizontalUnitPin(id: second, primaryName: "2")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        gate = try XCTUnwrap(entity.gates.keys.first)
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = [
            first: HorizontalSymbolPin(id: first, position: .init(x: -5_000_000, y: 0), length: 2_500_000),
            second: HorizontalSymbolPin(id: second, position: .init(x: 5_000_000, y: 0), length: 2_500_000),
        ]
        let package = HorizontalPoolItemFactory.newPackage()
        let resistor = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part = resistor.uuid
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: poolURL.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(resistor), to: poolURL.appendingPathComponent("parts/cache/\(resistor.uuid).json"))
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
    }

    @discardableResult
    private func apply(_ ops: [JSONDictionary]) throws -> [JSONDictionary] {
        let edited = try HorizontalCanvasProjectEdit.archive(applying: ops, to: archive, in: project)
        archive = edited.archive
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        return edited.changes
    }

    /// R1 and R2 drawn on the first sheet, nothing wired.
    private func placeResistors(_ refdes: [String] = ["R1", "R2"]) throws {
        try apply(refdes.enumerated().flatMap { offset, refdes -> [JSONDictionary] in [
            ["op": "ensure_component", "refdes": refdes, "part": part],
            ["op": "place_symbol", "component": refdes, "gate": gate, "x_mm": 20 + 30 * offset, "y_mm": 20],
        ] })
    }

    private func findings(_ rules: HorizontalSchematicRules = .init()) -> [HorizontalSchematicRuleFinding] {
        HorizontalSchematicRulesCheck.findings(project: project, archive: archive, rules: rules)
    }

    private func messages(_ rules: HorizontalSchematicRules = .init()) -> Set<String> {
        Set(findings(rules).map(\.message))
    }

    private var sheet: HorizontalSchematicSheet {
        get throws { try XCTUnwrap(project.schematic?.sheets.first) }
    }

    func testAPinOnNoNetFailsWhereItsSymbolDrawsItUntilMarkedNoConnect() throws {
        try placeResistors(["R1"])
        let found = findings()
        XCTAssertEqual(Set(found.map(\.message)), ["Pin R1.1 is not connected", "Pin R1.2 is not connected"])
        XCTAssertTrue(found.allSatisfy { $0.check == .unconnectedPin && $0.isError })

        // Placed where the wire would start: the pin's end on the sheet.
        let sheet = try sheet
        let pinEnds = Set(sheet.symbolPins.filter { $0.id.contains("/pin/") }.map { HorizontalCanvasModeSupport.pointKey($0.from) })
        XCTAssertEqual(pinEnds.count, 2)
        for finding in found {
            let place = try XCTUnwrap(finding.place)
            XCTAssertEqual(place.sheetID, sheet.id)
            XCTAssertTrue(pinEnds.contains(HorizontalCanvasModeSupport.pointKey(place.position)), finding.message)
        }

        try apply([["op": "set_no_connect", "component": "R1", "pin": "2"]])
        XCTAssertEqual(messages(), ["Pin R1.1 is not connected"], "a no-connect pin is connected as far as the rule goes")
    }

    func testAGateNoSheetDrawsHasItsPinsReportedWithoutAPlace() throws {
        try apply([["op": "ensure_component", "refdes": "R3", "part": part]])
        let found = findings()
        XCTAssertEqual(Set(found.map(\.message)), [
            "Pin R3.1 is not connected (not found in schematic)",
            "Pin R3.2 is not connected (not found in schematic)",
        ])
        XCTAssertTrue(found.allSatisfy { $0.place == nil })
    }

    func testANetOnlyOnePinIsOnFailsUntilAnotherPinJoinsIt() throws {
        try placeResistors()
        try apply([
            ["op": "ensure_net", "name": "SIG"],
            ["op": "connect", "component": "R1", "pin": "1", "net": "SIG"],
            ["op": "set_no_connect", "component": "R1", "pin": "2"],
            ["op": "set_no_connect", "component": "R2", "pins": ["1", "2"]],
        ])
        let found = findings()
        XCTAssertEqual(found.map(\.message), [#"Net "SIG" only connected to R1.1"#])
        let onePin = try XCTUnwrap(found.first)
        XCTAssertEqual(onePin.check, .onePinNet)
        XCTAssertTrue(onePin.isError)
        XCTAssertEqual(onePin.place?.sheetID, try sheet.id)

        try apply([
            ["op": "set_no_connect", "component": "R2", "pin": "1", "no_connect": false],
            ["op": "connect", "component": "R2", "pin": "1", "net": "SIG"],
        ])
        XCTAssertFalse(messages().contains { $0.hasPrefix("Net \"SIG\"") }, "two pins are on it")
    }

    func testAnUnnamedNetCountsOnlyWithIncludeUnnamedNetsAndADisabledRuleFindsNothing() throws {
        try placeResistors(["R1"])
        try apply([
            ["op": "connect", "component": "R1", "pin": "1", "create_net": true],
            ["op": "set_no_connect", "component": "R1", "pin": "2"],
        ])
        XCTAssertEqual(messages(), ["Unnamed net only connected to R1.1"])
        XCTAssertEqual(messages(.init(includeUnnamedNets: false)), [])
        XCTAssertEqual(findings(.init(connectivityEnabled: false)), [])
    }

    func testANetOnlyOneOfWhoseSegmentsHasALabelIsAWarning() throws {
        try placeResistors()
        try apply([
            ["op": "terminate_pin", "component": "R1", "pin": "1", "kind": "label", "net": "SIG", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "1", "net": "SIG"],
            ["op": "set_no_connect", "component": "R1", "pin": "2"],
            ["op": "set_no_connect", "component": "R2", "pin": "2"],
        ])
        let found = findings()
        XCTAssertEqual(found.map(\.message), [#"Net "SIG" only has one net segment with a label"#])
        let warning = try XCTUnwrap(found.first)
        XCTAssertEqual(warning.check, .oneLabelNet)
        XCTAssertFalse(warning.isError, "Horizon warns of it")
        let label = try XCTUnwrap(try sheet.netLabels.first)
        XCTAssertEqual(warning.place?.position, label.position, "drawn at the label")

        try apply([["op": "terminate_pin", "component": "R2", "pin": "1", "kind": "label", "net": "SIG"]])
        XCTAssertEqual(findings(), [], "both segments are labelled")
    }

    func testABlockInstancesPortOnNoNetFailsAtThePortUntilWired() throws {
        let channel = "0c0c0c0c-1111-4222-8333-444455556666"
        try apply([["op": "add_block", "name": "Channel", "id": channel]])
        let edited = try HorizontalCanvasProjectEdit.archive(applying: [
            ["op": "ensure_net", "name": "IN"],
            ["op": "set_net_port", "net": "IN", "is_port": true],
            ["op": "place_block_port", "net": "IN", "x_mm": 0, "y_mm": 0],
        ], to: archive, in: project, block: channel)
        archive = edited.archive
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        try apply([
            ["op": "add_block_instance", "block": "Channel", "refdes": "I1"],
            ["op": "place_block_symbol", "instance": "I1", "x_mm": 50, "y_mm": 50],
        ])

        let port = try XCTUnwrap(findings().first { $0.check == .unconnectedPort })
        XCTAssertEqual(port.message, "Port I1.IN is not connected")
        XCTAssertTrue(port.isError)
        let top = try XCTUnwrap(project.schematics.first { $0.block.isTop }?.schematic.sheets.first)
        XCTAssertEqual(port.place?.sheetID, top.id)
        let drawn = try XCTUnwrap(top.blockSymbolPorts.first { $0.id.contains("/block-port/") })
        XCTAssertEqual(port.place?.position, drawn.from, "at the end of the port a wire takes")

        try apply([["op": "connect_block_port", "instance": "I1", "port": "IN", "net": "X", "create_net": true]])
        XCTAssertFalse(findings().contains { $0.check == .unconnectedPort })
    }

    func testTheRulesReadTheOldNameAndAreWrittenAsConnectivityInTheTopSchematic() throws {
        let old: JSONDictionary = ["single_pin_net": ["enabled": false, "include_unnamed": false] as JSONDictionary]
        XCTAssertEqual(HorizontalSchematicRules(json: old), .init(connectivityEnabled: false, includeUnnamedNets: false))
        XCTAssertEqual(HorizontalSchematicRules(json: [:]), .init(), "a file without the rule has it enabled, as Horizon")

        let written = HorizontalSchematicRules(connectivityEnabled: true, includeUnnamedNets: false)
            .json(updating: old.merging(["kept": 1]) { $1 })
        XCTAssertNil(written["single_pin_net"])
        XCTAssertEqual(written.int("kept"), 1)
        XCTAssertEqual(written.dictionary("connectivity")?.bool("include_unnamed"), false)
        XCTAssertEqual(written.dictionary("connectivity")?.int("order"), -1)

        try HorizontalProjectJSONApplicator.apply(schematicRules: written, in: project, to: &archive)
        try placeResistors(["R1"])
        let read = HorizontalSchematicRules(json: try HorizontalProjectJSONApplicator.schematicRules(in: project, from: archive))
        XCTAssertEqual(read, .init(connectivityEnabled: true, includeUnnamedNets: false), "an edit after keeps them")
    }
}

/// The rules checks' findings as the canvases mark them and the results
/// sidebar sums them up: one marker per point with every message there, red
/// when any of them is an error.
final class RuleViolationMarkerTests: XCTestCase {
    private func finding(_ check: HorizontalSchematicRuleFinding.Check, _ message: String, sheet: String = "SHEET-1",
                         at position: HorizontalPoint) -> HorizontalSchematicRuleFinding {
        .init(check: check, message: message,
              place: .init(blockID: nil, sheetID: sheet, sheetIndex: 1, sheetName: "Main", position: position), subject: message)
    }

    /// The marker's fill: the triangle inside its rim.
    private func fill(_ marker: HorizontalCanvasWarning) -> HorizontalMetalRGBA {
        HorizontalCanvasWarningGeometry.triangles(for: [marker])[1].color
    }

    func testASheetsFindingsShareAMarkerWithItsWarningsAndAnErrorMakesItRed() throws {
        let pin = finding(.unconnectedPin, "Pin R1.1 is not connected", at: .zero)
        let label = finding(.oneLabelNet, #"Net "SIG" only has one net segment with a label"#, at: .init(x: 1_000_000, y: 0))
        let elsewhere = finding(.unconnectedPin, "Pin R2.1 is not connected", sheet: "SHEET-2", at: .zero)
        let markers = HorizontalCanvasWarning.markers(schematicFindings: [pin, label, elsewhere], sheetID: "sheet-1")
        XCTAssertEqual(markers.count, 2, "the other sheet's finding is not drawn here")

        let shown = HorizontalCanvasWarning.merging([.init(position: .zero, messages: ["Label missing"])], markers)
        XCTAssertEqual(shown.count, 2)
        let atPin = try XCTUnwrap(shown.first { $0.position == .zero })
        XCTAssertEqual(atPin.messages, ["Label missing", "Pin R1.1 is not connected"])
        XCTAssertTrue(atPin.isError)
        let atLabel = try XCTUnwrap(shown.first { $0.position != .zero })
        XCTAssertFalse(atLabel.isError, "Horizon warns of a one-label net")

        XCTAssertGreaterThan(fill(atPin).red, 0.8)
        XCTAssertLessThan(fill(atPin).green, 0.3, "an error is red")
        XCTAssertGreaterThan(fill(atLabel).green, 0.7, "a warning stays yellow")
    }

    func testAClearanceFindingIsAnErrorWhereItsCopperComesClosest() throws {
        let track = HorizontalClearanceFinding.Object(type: .track, id: "t", label: "Track", netID: "a", netName: "A")
        let pad = HorizontalClearanceFinding.Object(type: .pad, id: "p", label: "Pad U1.1", netID: "b", netName: "B")
        let finding = HorizontalClearanceFinding(
            check: .copper, first: track, second: pad, layers: [0], layer: 0, distance: 80_000, clearance: 100_000,
            ruleID: nil, ruleBrief: "", location: .init(x: 5_000_000, y: 2_000_000),
            firstPoint: .init(x: 5_000_000, y: 1_960_000), secondPoint: .init(x: 5_000_000, y: 2_040_000)
        )
        let marker = try XCTUnwrap(HorizontalCanvasWarning.markers(clearanceFindings: [finding]).first)
        XCTAssertEqual(marker.position, finding.location)
        XCTAssertTrue(marker.isError)
        XCTAssertEqual(marker.messages, ["\(finding.title): \(finding.detail)"])
    }

    func testNoIssuesWaitsForTheSchematicCheckAndItsErrorsMakeTheBadgeRed() {
        var state = HorizontalBoardRulesResultState(ruleTitle: "Design Rules", messages: [], clearanceFindings: [])
        XCTAssertFalse(state.hasNoIssues, "the schematic is not checked yet")
        state.schematicFindings = []
        XCTAssertTrue(state.hasNoIssues)

        state.schematicFindings = [finding(.oneLabelNet, "one label", at: .zero)]
        XCTAssertFalse(state.hasNoIssues)
        XCTAssertEqual(state.badgeCount, 1)
        XCTAssertEqual(state.badgeColor, .orange)
        state.schematicFindings?.append(finding(.unconnectedPin, "Pin R1.1 is not connected", at: .zero))
        XCTAssertEqual(state.badgeCount, 2)
        XCTAssertEqual(state.badgeColor, .red)
    }
}
