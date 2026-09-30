#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

@MainActor
final class SchematicDeletionTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var project: HorizontalProject
        @Published var revision = 0
        var archive: HorizontalProjectArchive
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        var error: Error?
        let undo = UndoManager()
        let target = HorizontalUndoTarget<HorizontalProjectArchive>()
        var sheet: HorizontalSchematicSheet { project.schematic!.sheets[1] }

        init(project: HorizontalProject, archive: HorizontalProjectArchive) {
            self.project = project
            self.archive = archive
            undo.groupsByEvent = false
            target.configure(currentValue: { [unowned self] in self.archive }, restoreValue: { [unowned self] in
                do { try self.install($0) } catch { self.error = error }
            })
        }

        func install(_ value: HorizontalProjectArchive) throws {
            var reloaded = try HorizontalProject.loadSnapshot(of: value)
            reloaded.rebaseURLs(onto: project)
            archive = value
            project = reloaded
            revision += 1
        }

        func delete(_ sheet: HorizontalSchematicSheet) {
            do {
                let edited = try HorizontalCanvasProjectEdit.archive(
                    deletingSelectionFrom: sheet, schematicURL: project.schematic!.url, to: archive, in: project
                )
                target.registerUndo(from: archive, actionName: "Delete", undoManager: undo)
                try install(edited)
            } catch { self.error = error }
        }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(
                sheet: state.sheet, allSheets: state.project.schematic!.sheets,
                viewport: $viewport, undoManager: state.undo,
                onSheetChange: { _ in XCTFail("Deleting components must use the project undo transaction") },
                onDeleteSelection: state.delete,
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                syncRevision: state.revision
            )
        }
    }

    func testGroupDeletionRemovesBoardPackagesAndSidebarEntriesAndUndoesTogether() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for canvas presentation") }
        let state = try fixture()
        let defaults = UserDefaults(suiteName: "schematic-deletion-\(UUID().uuidString)")!
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        let boardBefore = try XCTUnwrap(state.project.board)
        let originalPackages = boardBefore.packages
        XCTAssertEqual(Set(originalPackages.map(\.label)), ["R1", "R3"])
        XCTAssertEqual(boardBefore.unplacedObjects.map(\.label), ["R2"])
        XCTAssertEqual(state.sheet.symbols.count, 2)
        XCTAssertEqual(state.sheet.texts.count, 1)

        state.actions?.dispatch(.selectAll)
        let selected = await settle {
            state.actions?.canDeleteSelection == true && state.details.groups.flatMap(\.items).count >= 3
        }
        XCTAssertTrue(selected)
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.deleteSelection)
        state.undo.endUndoGrouping()
        let deleted = await settle { state.revision == 1 }
        XCTAssertTrue(deleted)
        XCTAssertNil(state.error)
        try assertDeleted(state.project)
        XCTAssertTrue(state.undo.canUndo)
        XCTAssertEqual(state.undo.undoActionName, "Delete")

        state.undo.undo()
        let restored = await settle { state.revision == 2 }
        XCTAssertTrue(restored)
        XCTAssertEqual(state.project.board?.packages.sorted { $0.id < $1.id }, originalPackages.sorted { $0.id < $1.id },
                       "Undo restores footprint positions and identities")
        XCTAssertEqual(state.project.board?.unplacedObjects.map(\.label), ["R2"])
        XCTAssertEqual(state.sheet.symbols.count, 2)
        XCTAssertEqual(state.sheet.texts.count, 1, "Mixed selections restore in the same Undo step")
        XCTAssertFalse(state.undo.canUndo, "Deletion must register only one project-wide step")

        state.undo.redo()
        let redone = await settle { state.revision == 3 }
        XCTAssertTrue(redone)
        try assertDeleted(state.project)
        XCTAssertNil(state.error)

        let saved = state.project.baseURL.deletingLastPathComponent().appendingPathComponent("Saved.horizontal")
        try state.archive.write(to: saved)
        try assertDeleted(HorizontalProject.load(from: saved))
        let boardJSON = try json("board.json", in: state.archive)
        XCTAssertEqual(boardJSON.dictionaryMap("packages").count, 1, "The footprint must also be removed from the saved board")
        XCTAssertEqual(boardJSON.dictionaryMap("tracks").count, 1, "Deleting a footprint preserves routed copper")
        let track = try XCTUnwrap(boardJSON.dictionaryMap("tracks").values.first)
        XCTAssertNil(track.dictionary("from")?.string("pad"), "Copper must not reference a deleted pad")
        XCTAssertNotNil(track.dictionary("from")?.string("junc"))
    }

    func testDeletingOneGateKeepsAComponentStillUsedOnAnotherSheet() throws {
        let state = try fixture(otherGate: true)
        var draft = state.sheet
        draft.symbols = []
        let edited = try HorizontalCanvasProjectEdit.archive(
            deletingSelectionFrom: draft, schematicURL: state.project.schematic!.url, to: state.archive, in: state.project
        )
        let reloaded = try HorizontalProject.loadSnapshot(of: edited)
        XCTAssertEqual(Set(try XCTUnwrap(reloaded.board).packages.map(\.label)), ["R1", "R3"])
        XCTAssertEqual(Set(try json("top_block.json", in: edited).dictionaryMap("components").values.compactMap { $0.string("refdes") }), ["R1", "R3"])
        XCTAssertEqual(reloaded.schematic?.sheets[0].symbols.count, 2)
        XCTAssertEqual(reloaded.schematic?.sheets[1].symbols.count, 0)
    }

    private func assertDeleted(_ project: HorizontalProject, file: StaticString = #filePath, line: UInt = #line) throws {
        let board = try XCTUnwrap(project.board)
        XCTAssertEqual(board.packages.map(\.label), ["R3"], file: file, line: line)
        XCTAssertEqual(board.placeableObjects.map(\.label), ["R3"], file: file, line: line)
        XCTAssertTrue(board.unplacedObjects.isEmpty, file: file, line: line)
        let sheets = try XCTUnwrap(project.schematic?.sheets)
        XCTAssertEqual(sheets[0].symbols.count, 1, file: file, line: line)
        XCTAssertTrue(sheets[1].symbols.isEmpty, file: file, line: line)
        XCTAssertTrue(sheets[1].texts.isEmpty, file: file, line: line)
        for sheet in sheets {
            XCTAssertEqual(Set(sheet.componentInfo.values.map(\.refdes)), ["R3"], file: file, line: line)
            XCTAssertFalse(sheet.placeableObjects.contains { $0.label.hasPrefix("R1") || $0.label.hasPrefix("R2") }, file: file, line: line)
            XCTAssertFalse(sheet.unplacedObjects.contains { $0.label.hasPrefix("R1") || $0.label.hasPrefix("R2") }, file: file, line: line)
        }
    }

    private func settle(until predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func json(_ path: String, in archive: HorizontalProjectArchive) throws -> JSONDictionary {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    private func fixture(otherGate: Bool = false) throws -> State {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schematic-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let poolURL = url.appendingPathComponent("pool")
        var unit = HorizontalPoolItemFactory.newUnit()
        let pin = HorizontalPoolItemFactory.newUUID()
        unit.pins = [pin: HorizontalUnitPin(id: pin, primaryName: "1")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let gate = try XCTUnwrap(entity.gates.keys.first)
        let auxiliaryGate = HorizontalPoolItemFactory.newUUID()
        if otherGate {
            var auxiliary = try XCTUnwrap(entity.gates[gate])
            auxiliary.id = auxiliaryGate
            auxiliary.name = "Aux"
            auxiliary.suffix = "B"
            entity.gates[auxiliaryGate] = auxiliary
        }
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = [pin: HorizontalSymbolPin(id: pin, position: .zero, length: 2_500_000)]
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shape: HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        let pad = HorizontalPoolItemFactory.newUUID()
        package.pads[pad] = HorizontalPad(id: pad, name: "1", padstackID: padstack.uuid,
                                          placement: HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: false))
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.padMap = [pad: HorizontalPartPadMapEntry(gateID: gate, pinID: pin)]
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: poolURL.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        let project = try HorizontalProject.load(from: url)
        var operations: [JSONDictionary] = [
            ["op": "add_sheet", "name": "Second"],
            ["op": "ensure_component", "refdes": "R1", "part": part.uuid],
            ["op": "ensure_component", "refdes": "R2", "part": part.uuid],
            ["op": "ensure_component", "refdes": "R3", "part": part.uuid],
            ["op": "place_symbol", "component": "R1", "gate": gate, "sheet": 2, "x_mm": 10, "y_mm": 10],
            ["op": "place_symbol", "component": "R2", "gate": gate, "sheet": 2, "x_mm": 20, "y_mm": 10],
            ["op": "place_symbol", "component": "R3", "gate": gate, "sheet": 1, "x_mm": 10, "y_mm": 10],
            ["op": "place_text", "text": "Delete with the group", "sheet": 2, "x_mm": 15, "y_mm": 20],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": "R3", "x_mm": 20, "y_mm": 10],
            ["op": "connect", "component": "R1", "pin": "\(gate)/\(pin)", "net": "SIG", "create_net": true],
            ["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 15, "y_mm": 10], "layer": 0, "width_mm": 0.2]
        ]
        if otherGate {
            operations.append(["op": "place_symbol", "component": "R1", "gate": auxiliaryGate, "sheet": 1, "x_mm": 20, "y_mm": 10])
        }
        let seeded = try HorizontalCanvasProjectEdit.archive(
            applying: operations, to: HorizontalProjectArchive.completeProject(from: url), in: project
        ).archive
        var reloaded = try HorizontalProject.loadSnapshot(of: seeded)
        reloaded.rebaseURLs(onto: project)
        return State(project: reloaded, archive: seeded)
    }
}
#endif
