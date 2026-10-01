import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative
#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
#endif

final class SchematicClipboardTests: XCTestCase {
    struct Fixture {
        var archive: HorizontalProjectArchive
        var project: HorizontalProject
        var sheet: HorizontalSchematicSheet { project.schematic!.sheets[0] }
    }

    func testNamedNetsReconnectAndUnnamedNetsAreFreshOnEveryPaste() throws {
        let source = try fixture()
        let clipboard = try copy(allRefs(source.sheet), from: source)
        let originalBlock = try block(source.archive)
        let originalNames = originalBlock.dictionaryMap("nets")
        let namedID = try XCTUnwrap(originalNames.first { $0.value.string("name") == "VCC" }?.key)
        let unnamedID = try XCTUnwrap(originalNames.first { $0.value.string("name") == "" }?.key)
        let first = try paste(clipboard, into: source)
        let firstBlock = try block(first.archive)
        XCTAssertEqual(firstBlock.dictionaryMap("components").count, 4)
        XCTAssertEqual(Set(firstBlock.dictionaryMap("components").values.compactMap { $0.string("refdes") }).count, 4)
        XCTAssertEqual(firstBlock.dictionaryMap("nets").filter { $0.value.string("name") == "VCC" }.map(\.key), [namedID])
        let unnamed = firstBlock.dictionaryMap("nets").filter { $0.value.string("name") == "" }.map(\.key)
        XCTAssertEqual(unnamed.count, 2)
        XCTAssertTrue(unnamed.contains(unnamedID))
        let pastedComponents = firstBlock.dictionaryMap("components").filter { originalBlock.dictionaryMap("components")[$0.key] == nil }
        XCTAssertEqual(firstBlock["group_names"] as? [String: String], originalBlock["group_names"] as? [String: String])
        XCTAssertEqual(firstBlock["tag_names"] as? [String: String], originalBlock["tag_names"] as? [String: String])
        XCTAssertEqual(Set(pastedComponents.values.compactMap { $0.string("group") }),
                       Set(originalBlock.dictionaryMap("components").values.compactMap { $0.string("group") }))
        let connections = pastedComponents.values.flatMap { $0.dictionaryMap("connections").values.compactMap { $0.string("net") } }
        XCTAssertTrue(connections.contains(namedID))
        XCTAssertFalse(connections.contains(unnamedID), "Unnamed internal wiring must not connect to the original circuit")
        let next = Fixture(archive: first.archive, project: try HorizontalProject.loadSnapshot(of: first.archive))
        let second = try paste(clipboard, into: next)
        XCTAssertEqual(try block(second.archive).dictionaryMap("nets").filter { $0.value.string("name") == "" }.count, 3)
        XCTAssertEqual(second.sheet.symbols.count, 6)
    }

    func testPartialSelectionDropsHiddenConnectionsAndDetachesUnselectedPins() throws {
        let source = try fixture()
        let symbol = try XCTUnwrap(source.sheet.symbols.first { $0.label == "R1" })
        let line = try XCTUnwrap(source.sheet.netLines.first { source.sheet.netDetails[$0.netID ?? ""]?.name == "VCC" })
        let clipboard = try copy([.init(id: symbol.id, type: .schematicSymbol), .init(id: line.id, type: .lineNet)], from: source)
        let copied = try XCTUnwrap(clipboard.json.dictionaryMap("components").values.first)
        let connections = copied.dictionaryMap("connections")
        XCTAssertEqual(connections.count, 2, "Only the copied wire and the explicit no-connect survive")
        XCTAssertEqual(connections.values.filter { $0.string("net") == nil || $0.string("net") == HorizontalProjectArchive.nullUUID }.count, 1)
        let wire = try XCTUnwrap(clipboard.json.dictionaryMap("net_lines").values.first)
        XCTAssertNotNil(wire.dictionary("to")?.string("junc"))
        XCTAssertNil(wire.dictionary("to")?.string("pin"))
        let prepared = try paste(clipboard, into: source)
        XCTAssertEqual(prepared.sheet.symbols.count, 3)
        XCTAssertEqual(prepared.sheet.netLines.count, 3)
    }

    func testSingleSymbolDoesNotCopyConnectionsToUnselectedWiring() throws {
        let source = try fixture()
        let symbol = try XCTUnwrap(source.sheet.symbols.first { $0.label == "R1" })
        let clipboard = try copy([.init(id: symbol.id, type: .schematicSymbol)], from: source)
        XCTAssertTrue(clipboard.json.dictionaryMap("nets").isEmpty)
        let component = try XCTUnwrap(clipboard.json.dictionaryMap("components").values.first)
        XCTAssertEqual(component.dictionaryMap("connections").count, 1, "Explicit NC stays; external net connections do not")
        let prepared = try paste(clipboard, into: source)
        XCTAssertEqual(prepared.sheet.symbols.count, 3)
    }

    func testClipboardRoundTripPastesIntoAnotherDocumentWithItsPartDefinitions() throws {
        let source = try fixture()
        let clipboard = try HorizontalSchematicClipboard(data: copy(allRefs(source.sheet), from: source).data())
        var destination = try fixture(empty: true)
        destination = try applying([["op": "ensure_net", "name": "VCC", "id": "destination-vcc"],
                                    ["op": "ensure_net", "name": "vcc", "id": "lowercase-vcc"]], to: destination)
        let prepared = try paste(clipboard, into: destination)
        let newBlock = try block(prepared.archive)
        XCTAssertEqual(newBlock.dictionaryMap("components").count, 2)
        XCTAssertEqual(newBlock.dictionaryMap("nets").filter { $0.value.string("name") == "VCC" }.map(\.key), ["destination-vcc"])
        XCTAssertNotNil(newBlock.dictionaryMap("nets")["lowercase-vcc"], "Matching is case-sensitive, as in Horizon")
        XCTAssertFalse(prepared.sheet.symbolPins.isEmpty, "The symbols and units arrived with the clipboard")
        let loaded = try HorizontalProject.loadSnapshot(of: prepared.archive)
        XCTAssertEqual(loaded.board?.unplacedObjects.count, 2, "Copied components are new board components")
        XCTAssertFalse(loaded.poolParts.isEmpty)
        let saved = destination.project.baseURL.deletingLastPathComponent().appendingPathComponent("Pasted.horizontal")
        try prepared.placedArchive(.identity, in: prepared.baseArchive).write(to: saved)
        let reopened = try HorizontalProject.load(from: saved)
        XCTAssertEqual(reopened.schematic?.sheets[0].symbols.count, 2)
        XCTAssertEqual(reopened.schematic?.sheets[0].netLines.count, 2)
    }

    func testPastingIntoAnotherSheetAndTransformingDoesNotMoveOriginalItems() throws {
        let source = try fixture()
        let clipboard = try copy(allRefs(source.sheet), from: source)
        let second = try XCTUnwrap(source.project.schematic?.sheets.last)
        let prepared = try HorizontalSchematicClipboardEditor.prepare(
            clipboard, at: .zero, sheetID: second.id, schematicURL: source.project.schematic!.url,
            archive: source.archive, project: source.project
        )
        let transform = HorizontalPlacementTransform(shift: HorizontalPoint(x: 30_000_000, y: 5_000_000), angle: 16_384, mirrored: true)
        let preview = prepared.preview(transform)
        let placed = try prepared.placedArchive(transform, in: source.archive)
        let reopened = try HorizontalProject.loadSnapshot(of: placed)
        let sheet = try XCTUnwrap(reopened.schematic?.sheets.last)
        XCTAssertEqual(sheet.symbols.sorted { $0.id < $1.id }, preview.symbols.sorted { $0.id < $1.id })
        XCTAssertEqual(sheet.junctions, preview.junctions)
        XCTAssertEqual(sheet.netLabels, preview.netLabels)
        XCTAssertEqual(sheet.texts, preview.texts)
        XCTAssertEqual(sheet.powerSymbols, preview.powerSymbols)
        for pin in preview.symbolPins where pin.id.contains("/pin/") {
            let reopenedPin = try XCTUnwrap(sheet.symbolPins.first { $0.id == pin.id })
            XCTAssertEqual(reopenedPin.from, pin.from)
            XCTAssertEqual(reopenedPin.to, pin.to)
        }
        XCTAssertEqual(sheet.netLines.sorted { $0.id < $1.id }, preview.netLines.sorted { $0.id < $1.id })
        let original = try schematic(source.archive).dictionaryMap("sheets")[source.sheet.id]!
        let unchanged = try schematic(placed).dictionaryMap("sheets")[source.sheet.id]!
        XCTAssertEqual(original as NSDictionary, unchanged as NSDictionary)
    }

    func testStandaloneNamedWireAndLabelKeepTheirNetWithoutCopyingComponents() throws {
        let source = try fixture()
        let wire = try XCTUnwrap(source.sheet.netLines.first { source.sheet.netDetails[$0.netID ?? ""]?.name == "VCC" })
        let refs = [HorizontalSelectableRef(id: wire.id, type: .lineNet)]
            + source.sheet.netLabels.map { .init(id: $0.id, type: .netLabel) }
        let clipboard = try copy(refs, from: source)
        XCTAssertTrue(clipboard.json.dictionaryMap("components").isEmpty)
        let prepared = try paste(clipboard, into: source)
        XCTAssertEqual(prepared.sheet.symbols.count, 2)
        XCTAssertEqual(prepared.sheet.netLines.filter { $0.netID == wire.netID }.count, 2)
        XCTAssertEqual(prepared.sheet.netLabels.filter { $0.netID == wire.netID }.count, 2)
    }

    func testAmbiguousDestinationNetNamesRejectPasteWithoutChangingArchive() throws {
        let source = try fixture()
        let clipboard = try copy(allRefs(source.sheet), from: source)
        let destination = try applying([["op": "ensure_net", "name": "VCC", "id": "another-vcc"]], to: source)
        let before = destination.archive
        XCTAssertThrowsError(try paste(clipboard, into: destination)) { error in
            XCTAssertTrue(HorizontalCanvasProjectEdit.message(for: error).contains("More than one net"))
        }
        XCTAssertEqual(destination.archive, before)
    }

    func testPendingPasteCannotOverwriteAnInterveningBoardEdit() throws {
        let source = try fixture()
        let prepared = try paste(copy(allRefs(source.sheet), from: source), into: source)
        let changed = try applying([["op": "place_board_text", "text": "Keep this edit", "layer": 0, "x_mm": 1, "y_mm": 1]], to: source)
        XCTAssertThrowsError(try prepared.placedArchive(.identity, in: changed.archive)) { error in
            XCTAssertTrue(HorizontalCanvasProjectEdit.message(for: error).contains("document changed"))
        }
        XCTAssertEqual(changed.project.board?.texts.first?.text, "Keep this edit")
    }

    func testBusNetTieAndDrawingDependenciesSurvivePasteAndPlacement() throws {
        var source = try fixture()
        source = try applying([
            ["op": "add_bus", "id": "bus-data", "name": "DATA"],
            ["op": "add_bus_member", "bus": "bus-data", "id": "member-vcc", "name": "VCC", "net": "VCC"],
            ["op": "place_bus_label", "bus": "bus-data", "x_mm": 50, "y_mm": 10],
            ["op": "place_bus_ripper", "bus": "bus-data", "member": "member-vcc", "x_mm": 55, "y_mm": 10],
            ["op": "add_net_tie", "primary": "VCC", "secondary": "GND", "id": "tie-vcc-gnd"],
            ["op": "place_net_tie", "net_tie": "tie-vcc-gnd", "from": ["x_mm": 60, "y_mm": 10], "to": ["x_mm": 62, "y_mm": 10]]
        ], to: source)
        var schematic = try schematic(source.archive)
        var sheets = schematic.dictionaryMap("sheets")
        var sheet = try XCTUnwrap(sheets[source.sheet.id])
        var junctions = sheet.dictionaryMap("junctions")
        junctions["draw-1"] = ["position": [0, 0]]
        junctions["draw-2"] = ["position": [1_000_000, 0]]
        junctions["draw-center"] = ["position": [500_000, 500_000]]
        sheet["junctions"] = junctions
        sheet["lines"] = ["draw-line": ["from": "draw-1", "to": "draw-2", "width": 100_000, "layer": 0]]
        sheet["arcs"] = ["draw-arc": ["from": "draw-1", "to": "draw-2", "center": "draw-center", "width": 100_000, "layer": 0]]
        sheets[source.sheet.id] = sheet
        schematic["sheets"] = sheets
        try HorizontalSchematicClipboardEditor.write(schematic, path: "top_schematic.json", archive: &source.archive)
        var loaded = try HorizontalProject.loadSnapshot(of: source.archive)
        loaded.rebaseURLs(onto: source.project)
        source.project = loaded
        let refs = source.sheet.busLabels.map { HorizontalSelectableRef(id: $0.id, type: .busLabel) }
            + Array(Set(source.sheet.busRipperLines.map { String($0.id.split(separator: "/")[0]) })).map { .init(id: $0, type: .busRipper) }
            + source.sheet.netTies.map { .init(id: $0.id, type: .schematicNetTie) }
            + source.sheet.drawingLines.map { .init(id: $0.id, type: .drawingLine) }
            + source.sheet.drawingArcs.map { .init(id: $0.id, type: .drawingArc) }
        let clipboard = try copy(refs, from: source)
        XCTAssertEqual(clipboard.json.dictionaryMap("buses").count, 1)
        XCTAssertEqual(clipboard.json.dictionaryMap("block_net_ties").count, 1)
        let destination = try fixture(empty: true)
        let prepared = try paste(clipboard, into: destination)
        let transform = HorizontalPlacementTransform(shift: HorizontalPoint(x: 2_000_000, y: 3_000_000), angle: 16_384, mirrored: true)
        let archive = try prepared.placedArchive(transform, in: destination.archive)
        let reloaded = try HorizontalProject.loadSnapshot(of: archive)
        let pasted = try XCTUnwrap(reloaded.schematic?.sheets.first)
        XCTAssertEqual(pasted.busLabels.count, 1)
        XCTAssertFalse(pasted.busRipperLines.isEmpty)
        XCTAssertEqual(pasted.netTies.count, 1)
        XCTAssertEqual(pasted.netTies.first?.netIDs.count, 2)
        XCTAssertEqual(pasted.drawingLines.count, 1)
        XCTAssertEqual(pasted.drawingArcs.count, 1)
        XCTAssertEqual(pasted.junctions, prepared.preview(transform).junctions)
        XCTAssertEqual(try block(archive).dictionaryMap("nets").count, 2)
    }

    func testTwoGatesOfOneComponentPasteAsOneNewComponent() throws {
        var source = try fixture()
        let r1 = try XCTUnwrap(source.sheet.symbols.first { $0.label == "R1" })
        let entityID = try XCTUnwrap(try block(source.archive).dictionaryMap("components")[r1.componentID!]?.string("entity"))
        let path = "pool/entities/cache/\(entityID).json"
        var entity = try HorizontalSchematicClipboardEditor.read(path, archive: source.archive)
        var gates = entity.dictionaryMap("gates")
        let secondGate = UUID().uuidString.lowercased()
        var gate = try XCTUnwrap(gates.values.first)
        gate["name"] = "Aux"
        gate["suffix"] = "B"
        gates[secondGate] = gate
        entity["gates"] = gates
        try HorizontalSchematicClipboardEditor.write(entity, path: path, archive: &source.archive)
        var reloaded = try HorizontalProject.loadSnapshot(of: source.archive)
        reloaded.rebaseURLs(onto: source.project)
        source.project = reloaded
        source = try applying([["op": "place_symbol", "component": "R1", "gate": secondGate, "x_mm": 40, "y_mm": 10]], to: source)
        let refs = source.sheet.symbols.filter { $0.componentID == r1.componentID }.map { HorizontalSelectableRef(id: $0.id, type: .schematicSymbol) }
        XCTAssertEqual(refs.count, 2)
        let clipboard = try copy(refs, from: source)
        let prepared = try paste(clipboard, into: source)
        XCTAssertEqual(try block(prepared.archive).dictionaryMap("components").count, 3)
        let pasted = prepared.sheet.symbols.filter { prepared.pastedIDs.contains($0.id) }
        XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(Set(pasted.compactMap(\.componentID)).count, 1)
        XCTAssertEqual(Set(pasted.compactMap(\.gateID)), [r1.gateID!, secondGate])
    }

    // Shared with the mounted canvas regression below. No user pool or document
    // is involved: all objects, including the part dependency closure, are local.
    func fixture(empty: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Circuit.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        if empty { return Fixture(archive: try .completeProject(from: url), project: try .load(from: url)) }
        let pool = url.appendingPathComponent("pool")
        var unit = HorizontalPoolItemFactory.newUnit()
        let pins = (1...4).map { _ in HorizontalPoolItemFactory.newUUID() }
        unit.pins = Dictionary(uniqueKeysWithValues: pins.enumerated().map { ($0.element, HorizontalUnitPin(id: $0.element, primaryName: "\($0.offset + 1)")) })
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let gate = try XCTUnwrap(entity.gates.keys.first)
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = Dictionary(uniqueKeysWithValues: pins.enumerated().map {
            ($0.element, HorizontalSymbolPin(id: $0.element, position: HorizontalPoint(x: 0, y: Double($0.offset) * 2_500_000), length: 2_500_000))
        })
        let package = HorizontalPoolItemFactory.newPackage()
        let part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: pool.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: pool.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: pool.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: pool.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: pool.appendingPathComponent("parts/cache/\(part.uuid).json"))
        var fixture = Fixture(archive: try .completeProject(from: url), project: try .load(from: url))
        fixture = try applying([
            ["op": "add_sheet", "name": "Destination"],
            ["op": "ensure_component", "refdes": "R1", "part": part.uuid, "group": "Amplifier", "tag": "input"],
            ["op": "ensure_component", "refdes": "R2", "part": part.uuid, "group": "Amplifier", "tag": "output"],
            ["op": "connect", "component": "R1", "pin": "1", "net": "VCC", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "1", "net": "VCC"],
            ["op": "connect", "component": "R1", "pin": "2", "net": "INTERNAL", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "2", "net": "INTERNAL"],
            ["op": "connect", "component": "R1", "pin": "3", "net": "GND", "create_net": true],
            ["op": "place_symbol", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_symbol", "component": "R2", "x_mm": 20, "y_mm": 10],
            ["op": "draw_net_line", "component": "R1", "pin": "1", "to_component": "R2", "to_pin": "1"],
            ["op": "draw_net_line", "component": "R1", "pin": "2", "to_component": "R2", "to_pin": "2"],
            ["op": "place_net_label", "net": "VCC", "x_mm": 5, "y_mm": 10],
            ["op": "place_power_symbol", "net": "GND", "x_mm": 10, "y_mm": 5],
            ["op": "place_text", "text": "Amplifier", "x_mm": 15, "y_mm": 20]
        ], to: fixture)
        var block = try block(fixture.archive)
        var nets = block.dictionaryMap("nets")
        let internalID = try XCTUnwrap(nets.first { $0.value.string("name") == "INTERNAL" }?.key)
        nets[internalID]?["name"] = ""
        block["nets"] = nets
        var components = block.dictionaryMap("components")
        let r1 = try XCTUnwrap(components.first { $0.value.string("refdes") == "R1" }?.key)
        var connections = components[r1]!.dictionaryMap("connections")
        connections["\(gate)/\(pins[3])"] = ["net": NSNull()]
        components[r1]?["connections"] = connections
        block["components"] = components
        try HorizontalSchematicClipboardEditor.write(block, path: "top_block.json", archive: &fixture.archive)
        var reloaded = try HorizontalProject.loadSnapshot(of: fixture.archive)
        reloaded.rebaseURLs(onto: fixture.project)
        fixture.project = reloaded
        return fixture
    }

    func applying(_ operations: [JSONDictionary], to fixture: Fixture) throws -> Fixture {
        let archive = try HorizontalCanvasProjectEdit.archive(applying: operations, to: fixture.archive, in: fixture.project).archive
        var project = try HorizontalProject.loadSnapshot(of: archive)
        project.rebaseURLs(onto: fixture.project)
        return Fixture(archive: archive, project: project)
    }

    func allRefs(_ sheet: HorizontalSchematicSheet) -> [HorizontalSelectableRef] {
        sheet.symbols.map { .init(id: $0.id, type: .schematicSymbol) }
            + sheet.netLines.map { .init(id: $0.id, type: .lineNet) }
            + sheet.netLabels.map { .init(id: $0.id, type: .netLabel) }
            + sheet.powerSymbols.map { .init(id: $0.id, type: .powerSymbol) }
            + sheet.texts.map { .init(id: $0.id, type: .text) }
    }

    func copy(_ refs: [HorizontalSelectableRef], from source: Fixture) throws -> HorizontalSchematicClipboard {
        try HorizontalSchematicClipboardEditor.copy(refs, from: source.sheet, schematicURL: source.project.schematic!.url,
                                                   anchor: .zero, archive: source.archive, project: source.project)
    }

    func paste(_ clipboard: HorizontalSchematicClipboard, into destination: Fixture) throws -> HorizontalSchematicPaste {
        try HorizontalSchematicClipboardEditor.prepare(clipboard, at: HorizontalPoint(x: 30_000_000, y: 0),
            sheetID: destination.sheet.id, schematicURL: destination.project.schematic!.url,
            archive: destination.archive, project: destination.project)
    }

    func block(_ archive: HorizontalProjectArchive) throws -> JSONDictionary {
        try HorizontalSchematicClipboardEditor.read("top_block.json", archive: archive)
    }

    func schematic(_ archive: HorizontalProjectArchive) throws -> JSONDictionary {
        try HorizontalSchematicClipboardEditor.read("top_schematic.json", archive: archive)
    }
}

#if os(macOS)
extension SchematicClipboardTests {
    @MainActor private final class CanvasState: ObservableObject {
        @Published var fixture: Fixture
        @Published var revision = 0
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        var error: Error?
        let undo = UndoManager()
        let target = HorizontalUndoTarget<Fixture>()

        init(_ fixture: Fixture) {
            self.fixture = fixture
            undo.groupsByEvent = false
            target.configure(currentValue: { [unowned self] in self.fixture }, restoreValue: { [unowned self] in
                self.fixture = $0
                self.revision += 1
            })
        }

        func copy(_ sheet: HorizontalSchematicSheet, _ refs: [HorizontalSelectableRef], _ point: HorizontalPoint) -> HorizontalSchematicClipboard? {
            do {
                return try HorizontalSchematicClipboardEditor.copy(refs, from: sheet, schematicURL: fixture.project.schematic!.url,
                    anchor: point, archive: fixture.archive, project: fixture.project)
            } catch { self.error = error; return nil }
        }

        func prepare(_ clipboard: HorizontalSchematicClipboard, _ point: HorizontalPoint, _ name: String) -> HorizontalSchematicPastePlacement? {
            do {
                let paste = try HorizontalSchematicClipboardEditor.prepare(clipboard, at: point,
                    sheetID: fixture.sheet.id, schematicURL: fixture.project.schematic!.url,
                    archive: fixture.archive, project: fixture.project)
                return HorizontalSchematicPastePlacement(paste: paste) { transform in
                    do {
                        let archive = try paste.placedArchive(transform, in: self.fixture.archive)
                        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
                        reloaded.rebaseURLs(onto: self.fixture.project)
                        self.target.registerUndo(from: self.fixture, actionName: name, undoManager: self.undo)
                        self.fixture = Fixture(archive: archive, project: reloaded)
                        self.revision += 1
                    } catch { self.error = error }
                }
            } catch { self.error = error; return nil }
        }
    }

    private struct ClipboardCanvas: View {
        @ObservedObject var state: CanvasState
        @State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(sheet: state.fixture.sheet, allSheets: state.fixture.project.schematic!.sheets,
                viewport: $viewport, undoManager: state.undo,
                onSheetChange: { _ in XCTFail("A paste must commit through the project transaction") },
                onCopySelection: state.copy, onPreparePaste: state.prepare,
                onClipboardError: { state.error = $0 },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 }, syncRevision: state.revision)
        }
    }

    @MainActor func testMountedDuplicatePreviewCancelCommitAndUndoRedo() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for the canvas") }
        _ = NSApplication.shared
        let state = CanvasState(try fixture())
        let original = state.fixture.archive
        let originalSymbols = state.fixture.sheet.symbols
        let defaults = UserDefaults(suiteName: "clipboard-canvas-\(UUID().uuidString)")!
        let hosted = NSHostingView(rootView: ClipboardCanvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        func settle(_ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            return predicate()
        }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canDuplicateSelection == true }
        XCTAssertTrue(selected)
        XCTAssertTrue(state.actions?.canCopySelection == true)
        XCTAssertTrue(state.actions?.canPasteSelection == true)
        state.actions?.dispatch(.duplicateSelection)
        let previewing = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(previewing)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.fixture.archive, original, "The cursor preview must not edit the document")
        XCTAssertFalse(state.undo.canUndo)
        state.actions?.dispatch(.moveSelectionBy(HorizontalPoint(x: 20_000_000, y: 0)))
        state.actions?.dispatch(.rotateSelection)
        state.actions?.dispatch(.mirrorSelection)
        state.actions?.dispatch(.cancelInteraction)
        let cancelled = await settle { state.actions?.canCommitInteraction == false }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(state.fixture.archive, original)
        XCTAssertFalse(state.undo.canUndo)

        state.actions?.dispatch(.duplicateSelection)
        let restarted = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(restarted)
        state.actions?.dispatch(.moveSelectionBy(HorizontalPoint(x: 20_000_000, y: 0)))
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.commitInteraction)
        state.undo.endUndoGrouping()
        let committed = await settle { state.revision == 1 }
        XCTAssertTrue(committed)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.fixture.sheet.symbols.count, 4)
        XCTAssertEqual(state.fixture.sheet.netLines.count, 4)
        XCTAssertEqual(state.undo.undoActionName, "Duplicate")
        let originalIDs = Set(try block(original).dictionaryMap("components").keys)
        let unchanged = state.fixture.sheet.symbols.filter { originalIDs.contains($0.componentID ?? "") }
        XCTAssertEqual(unchanged.sorted { $0.id < $1.id }, originalSymbols.sorted { $0.id < $1.id })
        let pastedPositions = state.fixture.sheet.symbols.filter { !originalIDs.contains($0.componentID ?? "") }
            .sorted { $0.label < $1.label }.map(\.position)
        XCTAssertEqual(pastedPositions[1] - pastedPositions[0], HorizontalPoint(x: 10_000_000, y: 0),
                       "The real mouse can update the cursor while mounted; the group must move rigidly")
        let pasted = state.fixture.archive
        state.undo.undo()
        let undone = await settle { state.revision == 2 }
        XCTAssertTrue(undone)
        XCTAssertEqual(state.fixture.archive, original)
        XCTAssertFalse(state.undo.canUndo)
        state.undo.redo()
        let redone = await settle { state.revision == 3 }
        XCTAssertTrue(redone)
        XCTAssertEqual(state.fixture.archive, pasted)
    }
}
#endif
