#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A request to place a part is taken by one canvas, once. Each schematic
/// file has a canvas of its own, made afresh when a sheet of another block is
/// shown, and a canvas's note of the request it last took goes with the
/// canvas. The window used to keep the request after its part was placed, so
/// the next block's sheet shown started the placement over again.
@MainActor
final class SchematicPlacementRequestTests: XCTestCase {
    @MainActor private final class Host: ObservableObject {
        @Published var request: HorizontalPartPlacementRequest?
        /// Off, then on again, as when another schematic file is shown: the
        /// canvas goes and one is made afresh.
        @Published var showsCanvas = true
        var actions: HorizontalCanvasCommandActions?
        var placed = [HorizontalSchematicSheet]()
        var taken = [UUID]()
    }

    private struct Canvas: View {
        @ObservedObject var host: Host
        var sheet: HorizontalSchematicSheet
        var poolURL: URL
        @State private var viewport = CanvasViewport()
        var body: some View {
            if host.showsCanvas {
                SchematicCanvasView(
                    sheet: sheet, allSheets: [sheet], viewport: $viewport,
                    onSheetChange: { host.placed.append($0) },
                    onCanvasCommandActionsChange: { host.actions = $0 },
                    placePartRequest: host.request,
                    // As the window does: what a canvas took is dropped.
                    onRequestTaken: { id in
                        host.taken.append(id)
                        if host.request?.id == id {
                            host.request = nil
                        }
                    },
                    poolURL: poolURL
                )
            } else {
                Color.clear
            }
        }
    }

    private func settle(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// The starter project with one part in its pool, a single-gate resistor.
    private func projectWithAPart() throws -> HorizontalProject {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("placement-request-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pool = root.appendingPathComponent("pool")
        var unit = HorizontalPoolItemFactory.newUnit()
        let pin = HorizontalPoolItemFactory.newUUID()
        unit.pins = [pin: HorizontalUnitPin(id: pin, primaryName: "1")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = [pin: HorizontalSymbolPin(id: pin, position: .zero, length: 2_500_000)]
        let package = HorizontalPoolItemFactory.newPackage()
        let part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: pool.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: pool.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: pool.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: pool.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: pool.appendingPathComponent("parts/cache/\(part.uuid).json"))
        return try HorizontalProject.load(from: root)
    }

    func testAPartPlacedIsNotPlacedAgainByTheNextCanvasMade() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for the canvas") }
        _ = NSApplication.shared
        let project = try projectWithAPart()
        let part = try XCTUnwrap(project.poolParts.first)
        let sheet = try XCTUnwrap(project.schematic?.sheets.first)
        let poolURL = project.baseURL.appendingPathComponent(try XCTUnwrap(project.poolDirectory))

        let host = Host()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "placement-request-\(UUID().uuidString)"))
        let hosted = NSHostingView(rootView: Canvas(host: host, sheet: sheet, poolURL: poolURL)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { host.actions != nil }
        XCTAssertTrue(mounted)

        // Place from the Parts pane: the part follows the cursor, and the
        // request is the canvas's now, no longer the window's.
        let request = HorizontalPartPlacementRequest(part: part)
        host.request = request
        let placing = await settle { host.actions?.canCommitInteraction == true }
        XCTAssertTrue(placing, "the part follows the cursor")
        XCTAssertEqual(host.taken, [request.id])
        XCTAssertNil(host.request, "the canvas took the request, and the window dropped it")

        host.actions?.dispatch(.commitInteraction)
        let placed = await settle { host.actions?.canCommitInteraction == false && host.placed.count == 1 }
        XCTAssertTrue(placed, "a click puts it down")
        XCTAssertEqual(host.placed.last?.symbols.count, sheet.symbols.count + 1)

        // Another block's sheet: its schematic's canvas is made afresh.
        host.showsCanvas = false
        let gone = await settle { host.actions == nil }
        XCTAssertTrue(gone)
        host.showsCanvas = true
        let back = await settle { host.actions != nil }
        XCTAssertTrue(back)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(host.actions?.canCommitInteraction, false, "nothing starts over on the sheet turned to")
        XCTAssertEqual(host.taken, [request.id], "the request was taken once")
        XCTAssertEqual(host.placed.count, 1)
    }

    /// A request the canvas can't start, a locked document's, is taken all the
    /// same: left set, it would start whenever a canvas next came up.
    func testARequestThatCannotStartIsStillTaken() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for the canvas") }
        _ = NSApplication.shared
        let project = try projectWithAPart()
        let part = try XCTUnwrap(project.poolParts.first)
        let sheet = try XCTUnwrap(project.schematic?.sheets.first)

        let host = Host()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "placement-request-\(UUID().uuidString)"))
        // No pool to draw the part's symbol from: the placement can't start.
        let hosted = NSHostingView(rootView: Canvas(host: host, sheet: sheet,
                                                    poolURL: project.baseURL.appendingPathComponent("no-such-pool"))
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { host.actions != nil }
        XCTAssertTrue(mounted)

        let request = HorizontalPartPlacementRequest(part: part)
        host.request = request
        let taken = await settle { host.request == nil }
        XCTAssertTrue(taken, "the window is told, and drops it")
        XCTAssertEqual(host.taken, [request.id])
        XCTAssertEqual(host.actions?.canCommitInteraction, false, "though nothing follows the cursor")
    }
}
#endif
