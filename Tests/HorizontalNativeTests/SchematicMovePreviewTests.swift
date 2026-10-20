#if os(macOS)
import AppKit
import HorizontalProjectIO
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// What a move preview draws, step by step, for a capacitor wired as Billo's
/// C1 is: a supply power symbol on a stub above its top pin, a ground one on
/// a shorter stub below the other. Every line the canvas holds for them has
/// to move by just what the selection has moved: a step that put a pin's end
/// on the junction its stub ran to moved that end twice, and the stub went.
@MainActor
final class SchematicMovePreviewTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalSchematicSheet
        var committed: HorizontalSchematicSheet?
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        init(_ sheet: HorizontalSchematicSheet) { source = sheet }
    }

    private struct Canvas: View {
        var state: State
        @SwiftUI.State private var sheet: HorizontalSchematicSheet
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: State) {
            self.state = state
            _sheet = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            SchematicCanvasView(sheet: sheet, viewport: $viewport, undoManager: state.undo,
                onSheetChange: { state.committed = $0; sheet = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 })
        }
    }

    /// C1, turned upright, with P12V 2.5 mm above its top pin and GND 1.25
    /// mm below its bottom one, through MCP's terminate_pin as Billo's are.
    private func sheet() throws -> HorizontalSchematicSheet {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("move-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let partID = try fabricateCapacitor(poolURL: url.appendingPathComponent("pool"))
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        let operations: [JSONDictionary] = [
            ["op": "ensure_component", "refdes": "C1", "part": partID],
            ["op": "place_symbol", "component": "C1", "x_mm": 20, "y_mm": 30, "angle_deg": 90],
            ["op": "terminate_pin", "component": "C1", "pin": "2", "kind": "power", "net": "P12V", "create_net": true, "length_mm": 2.5],
            ["op": "terminate_pin", "component": "C1", "pin": "1", "kind": "power", "net": "GND", "create_net": true, "length_mm": 1.25, "style": "gnd"],
        ]
        archive = try HorizontalCanvasProjectEdit.archive(applying: operations, to: archive, in: HorizontalProject.loadSnapshot(of: archive)).archive
        return try XCTUnwrap(HorizontalProject.loadSnapshot(of: archive).schematic?.sheets.first)
    }

    private func fabricateCapacitor(poolURL: URL) throws -> String {
        let pin1 = HorizontalPoolItemFactory.newUUID(), pin2 = HorizontalPoolItemFactory.newUUID()
        var unit = HorizontalPoolItemFactory.newUnit()
        unit.pins = [pin1: HorizontalUnitPin(id: pin1, primaryName: "1"), pin2: HorizontalUnitPin(id: pin2, primaryName: "2")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "C"
        let gateID = try XCTUnwrap(entity.gates.keys.first)
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shapeID = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shapeID: HorizontalPadstackShape(id: shapeID, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        var padIDs = [String]()
        for (index, name) in ["1", "2"].enumerated() {
            let padID = HorizontalPoolItemFactory.newUUID()
            padIDs.append(padID)
            package.pads[padID] = HorizontalPad(
                id: padID, name: name, padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: Double(index * 1_600_000 - 800_000), y: 0), angle: 0, mirrored: false)
            )
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.padMap = [padIDs[0]: HorizontalPartPadMapEntry(gateID: gateID, pinID: pin1),
                       padIDs[1]: HorizontalPartPadMapEntry(gateID: gateID, pinID: pin2)]
        part.attributes[.mpn] = HorizontalPartAttribute(value: "CAP")
        // Billo's capacitor: pins 3 mm long, off the 1.25 mm grid, ending
        // 3.75 mm either side of its middle.
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = [
            pin1: HorizontalSymbolPin(id: pin1, position: HorizontalPoint(x: -3_750_000, y: 0), length: 3_000_000),
            pin2: HorizontalSymbolPin(id: pin2, position: HorizontalPoint(x: 3_750_000, y: 0), length: 3_000_000),
        ]
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: poolURL.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        return part.uuid
    }

    private func renderer(in view: NSView) -> HorizontalMetalBackdropView.Renderer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           renderer.loadProfileLabel == "Metal overlay" { return renderer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    func testEveryStepOfAMovePreviewMovesTheWholeSelectionAlike() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for the canvas") }
        _ = NSApplication.shared
        let state = State(try sheet())
        XCTAssertEqual(state.source.powerSymbols.count, 2)
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        func settle(_ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            return predicate()
        }
        let mounted = await settle { state.actions != nil && self.renderer(in: hosted)?.presentedContentKey != nil }
        XCTAssertTrue(mounted)
        let renderer = try XCTUnwrap(renderer(in: hosted))
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)

        // Symbols, wires and power symbols, as the canvas files them.
        let groups = [4, 5, 9]
        func lines() -> [Int: [(from: SIMD2<Float>, to: SIMD2<Float>)]] {
            Dictionary(uniqueKeysWithValues: groups.map { ($0, renderer.residentLineEndpoints(compositeGroup: $0)) })
        }
        let before = lines()
        for group in groups { XCTAssertFalse(before[group, default: []].isEmpty, "group \(group)") }
        // Twelve steps down, then twenty-four up, as the arrow keys go.
        let step: Float = 1_250_000
        let offsets = (1...12).map { -$0 } + (-11...12).map { $0 }
        var previous = 0
        for steps in offsets {
            state.actions?.dispatch(.moveSelectionBy(HorizontalPoint(x: 0, y: Double(step) * Double(steps - previous))))
            previous = steps
            let offset = step * Float(steps)
            let moved = await settle {
                let now = renderer.residentLineEndpoints(compositeGroup: 4)
                return now.count == before[4]?.count && abs((now.first?.from.y ?? 0) - ((before[4]?.first?.from.y ?? 0) + offset)) < 16
            }
            XCTAssertTrue(moved, "\(steps) steps drew")
            let now = lines()
            for group in groups {
                let original = before[group, default: []], preview = now[group, default: []]
                XCTAssertEqual(preview.count, original.count, "\(steps) steps, group \(group)")
                // The buffers hold Float, a few nanometres apart this far
                // from the origin.
                let tolerance: Float = 16
                for (index, (was, is_)) in zip(original, preview).enumerated()
                    where abs(is_.from.x - was.from.x) > tolerance || abs(is_.from.y - (was.from.y + offset)) > tolerance
                        || abs(is_.to.x - was.to.x) > tolerance || abs(is_.to.y - (was.to.y + offset)) > tolerance {
                    XCTFail("\(steps) steps, group \(group), line \(index): \(was) drawn at \(is_)")
                }
            }
        }
        state.actions?.dispatch(.cancelInteraction)
    }
}
#endif
