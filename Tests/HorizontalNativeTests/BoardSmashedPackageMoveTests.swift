#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Select All on a board whose packages are smashed moves as quickly as on
/// one whose packages are not. Select All takes in the smashed refdes, which
/// the canvas draws as its package's, and a text of a package was never drawn
/// by patching the resident scene, so each step rebuilt the board moved and
/// its whole scene; and the move of every selected track asked who owns its
/// ends of every package's pads anew. Weevling (26 packages, all smashed, 213
/// tracks) took 22 to 48 s a nudge and 88 s to commit, in Debug.
@MainActor
final class BoardSmashedPackageMoveTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct Canvas: View {
        var state: State
        @SwiftUI.State private var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: State) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); board = $0 },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let silk = HorizontalBoardLayers.topSilkscreen

    /// `count` packages in rows, each smashed, with its refdes a board text of
    /// its own below it, `padsEach` pads in a row on nets of their own, and a
    /// track from each of the first `tracksEach` up to a junction.
    private func board(packages count: Int, padsEach: Int, tracksEach: Int) -> HorizontalBoard {
        var packages = [HorizontalPlacement]()
        var pads = [HorizontalPolygon]()
        var padPositions = [String: HorizontalPoint]()
        var texts = [HorizontalText]()
        var tracks = [HorizontalSegment]()
        var junctions = [String: HorizontalPoint]()
        var junctionNetIDs = [String: String]()
        for index in 0..<count {
            let id = "p\(index)"
            let origin = HorizontalPoint(x: Double(index % 6) * 20 * mm, y: Double(index / 6) * 10 * mm)
            packages.append(HorizontalPlacement(id: id, position: origin, angle: 0, mirrored: false,
                                                label: "R\(index)", componentID: "c\(index)", smashed: true))
            texts.append(HorizontalText(id: "\(id)/text/rd", text: "R\(index)", position: origin + HorizontalPoint(x: 1 * mm, y: -2 * mm),
                                        size: mm, layer: silk, fromSmash: true,
                                        placeholder: HorizontalTextPlaceholder(stored: "$RD", drawn: "R\(index)")))
            for pad in 0..<padsEach {
                let center = origin + HorizontalPoint(x: Double(pad) * 0.5 * mm, y: 0)
                let half = 0.15 * mm
                let net = "\(id)-n\(pad)"
                pads.append(HorizontalPolygon(id: "\(id)/pad/k\(pad)/shape/s", vertices: [
                    .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
                    .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
                ], layer: top, netID: net))
                padPositions["\(id)/k\(pad)"] = center
                guard pad < tracksEach else { continue }
                let junction = "\(id)-j\(pad)"
                let bend = center + HorizontalPoint(x: 0, y: 2 * mm)
                junctions[junction] = bend
                junctionNetIDs[junction] = net
                tracks.append(HorizontalSegment(id: "\(id)-t\(pad)", from: center, to: bend, width: 150_000, layer: top,
                                                netID: net, toJunctionID: junction))
            }
        }
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/smashed-package-move.hprj"), uuid: "b", name: "smashed package move",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: junctions, junctionNetIDs: junctionNetIDs, netDetails: [:], tracks: tracks,
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: packages, packagePads: pads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: texts, texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = padPositions
        return board
    }

    private func settle(within timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    /// The layer of the board's own scene, under the selection overlay.
    private func renderer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal overlay") { return layer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    private typealias Key = (UInt16, String) throws -> Void

    /// Mounts the canvas and selects everything.
    private func mount(_ state: State) async throws -> (window: NSWindow, renderer: HorizontalMetalCanvasLayer, key: Key) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        let mounted = await settle(within: 30) {
            state.actions != nil && self.monitor(in: hosted) != nil && self.renderer(in: hosted)?.presentedContentKey != nil
        }
        XCTAssertTrue(mounted)
        let renderer = try XCTUnwrap(renderer(in: hosted))
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let key: Key = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        return (window, renderer, key)
    }

    private typealias Strokes = [(from: SIMD2<Float>, to: SIMD2<Float>)]

    /// How far up every stroke went from `before`, or nil unless all of them
    /// went up by one amount.
    private func rise(_ strokes: Strokes, from before: Strokes) -> Float? {
        guard strokes.count == before.count, let first = strokes.first, let start = before.first else { return nil }
        let dy = first.from.y - start.from.y
        let moved = zip(strokes, before).allSatisfy { now, was in
            abs(now.from.x - was.from.x) < 2 && abs(now.to.x - was.to.x) < 2
                && abs(now.from.y - was.from.y - dy) < 2 && abs(now.to.y - was.to.y - dy) < 2
        }
        return moved && dy > 1 ? dy : nil
    }

    private func silkStrokes(_ renderer: HorizontalMetalCanvasLayer) -> Strokes {
        renderer.residentLineEndpoints(compositeGroup: BoardLayerStyle.compositeGroup(for: silk))
    }

    /// Everything moved by one shift: the packages, their pads and smashed
    /// texts, the tracks and the junctions they end on.
    private func assertMovedWhole(_ moved: HorizontalBoard, from board: HorizontalBoard, file: StaticString = #filePath, line: UInt = #line) {
        guard let delta = moved.packages.first.map({ $0.position - board.packages[0].position }) else {
            return XCTFail("no package", file: file, line: line)
        }
        XCTAssertGreaterThan(delta.y, 0, "it went up", file: file, line: line)
        XCTAssertEqual(delta.x, 0, file: file, line: line)
        XCTAssertEqual(zip(moved.packages, board.packages).map { $0.position - $1.position },
                       Array(repeating: delta, count: board.packages.count), "every package", file: file, line: line)
        func byID<T>(_ items: [T], _ id: (T) -> String) -> [String: T] {
            Dictionary(items.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        }
        let texts = byID(moved.packageTexts, \.id)
        XCTAssertTrue(board.packageTexts.allSatisfy { texts[$0.id].map { $0.position - delta } == $0.position },
                      "every smashed refdes", file: file, line: line)
        let tracks = byID(moved.tracks, \.id)
        XCTAssertTrue(board.tracks.allSatisfy { track in
            tracks[track.id].map { $0.from - delta == track.from && $0.to - delta == track.to } == true
        }, "every track, once", file: file, line: line)
        XCTAssertTrue(board.junctions.allSatisfy { id, point in moved.junctions[id].map { $0 - delta } == point },
                      "every junction, once", file: file, line: line)
        let pads = byID(moved.packagePads, \.id)
        XCTAssertTrue(board.packagePads.allSatisfy { pad in
            pads[pad.id].map { HorizontalRect(points: $0.vertices).center - delta } == HorizontalRect(points: pad.vertices).center
        }, "every pad", file: file, line: line)
    }

    func testSelectAllMovesSmashedPackagesByPatchingTheScene() async throws {
        let state = State(board(packages: 2, padsEach: 2, tracksEach: 1))
        let (window, renderer, key) = try await mount(state)
        defer { window.close() }
        let before = silkStrokes(renderer)
        XCTAssertFalse(before.isEmpty, "the smashed refdes are drawn")

        try key(126, "\u{f700}")   // up
        let previewed = await settle { self.rise(self.silkStrokes(renderer), from: before) != nil }
        XCTAssertTrue(previewed, "the refdes go up with their packages")
        // The first step uploads the scene's resident metadata once; from then
        // on a patched move draws each step on the scene it has. That upload
        // can land after the moved strokes show, so let it settle first.
        try await Task.sleep(for: .milliseconds(300))
        let firstStep = silkStrokes(renderer)
        let uploads = renderer.residentSceneUploads
        try key(126, "\u{f700}")
        let stepped = await settle { self.rise(self.silkStrokes(renderer), from: firstStep) != nil }
        XCTAssertTrue(stepped, "and again")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(renderer.residentSceneUploads, uploads,
                       "the second step patches the scene; it is not built again with the board moved")

        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        assertMovedWhole(try XCTUnwrap(state.committed.last), from: state.source)
    }

    /// R and E turn and mirror a smashed refdes once with its package, as they
    /// move it: the package carries it, and it was turned or mirrored again as
    /// a selected text.
    func testRAndEOnSelectAllTurnAndMirrorASmashedRefdesOnce() async throws {
        let source = board(packages: 1, padsEach: 2, tracksEach: 1)
        let package = source.packages[0], text = source.packageTexts[0]
        let offset = text.position - package.position

        for (code, letter) in [(UInt16(15), "r"), (UInt16(14), "e")] {
            let state = State(source)
            let (window, _, key) = try await mount(state)
            defer { window.close() }
            try key(code, letter)
            let committed = await settle { state.committed.count == 1 }
            XCTAssertTrue(committed, letter)
            let changed = try XCTUnwrap(state.committed.last)
            let turnedPackage = try XCTUnwrap(changed.packages.first), turnedText = try XCTUnwrap(changed.packageTexts.first)
            let now = turnedText.position - turnedPackage.position
            if letter == "r" {
                // Horizon's angles: 65536 a turn.
                func quarter(_ angle: Int) -> Int { (angle % 65536 + 65536) % 65536 }
                let turn = quarter(turnedPackage.angle - package.angle)
                XCTAssertTrue(turn == 16384 || turn == 49152, "a quarter turn: \(turn)")
                let expected = turn == 16384 ? HorizontalPoint(x: -offset.y, y: offset.x) : HorizontalPoint(x: offset.y, y: -offset.x)
                XCTAssertEqual(now.x, expected.x, accuracy: 1, "the refdes turned once about the package")
                XCTAssertEqual(now.y, expected.y, accuracy: 1)
                XCTAssertEqual(quarter(turnedText.angle - text.angle), turn, "and is turned as far")
            } else {
                XCTAssertNotEqual(turnedPackage.mirrored, package.mirrored, "the package went to the other side")
                XCTAssertEqual(now.x, -offset.x, accuracy: 1, "the refdes mirrored once with it")
                XCTAssertEqual(now.y, offset.y, accuracy: 1)
                XCTAssertEqual(turnedText.layer, HorizontalBoardLayers.bottomSilkscreen, "onto the other side's silkscreen, once")
            }
        }
    }

    /// A smashed refdes moved on its own still goes where it is taken, drawn
    /// from a scene built with it moved, since its package's spans, which
    /// draw it, stay.
    func testASmashedRefdesMovedWithoutItsPackageIsDrawnWhereItGoes() async throws {
        let state = State(board(packages: 1, padsEach: 2, tracksEach: 1))
        let (window, renderer, key) = try await mount(state)
        defer { window.close() }
        try key(4, "h")   // on a package smashed already, H selects its smashed refdes
        let refdes = await settle { state.details.groups.map(\.type) == [.text] }
        XCTAssertTrue(refdes, "\(state.details.groups.map(\.type))")
        let before = silkStrokes(renderer)
        let copper = renderer.residentLineEndpoints(compositeGroup: BoardLayerStyle.compositeGroup(for: top))

        try key(126, "\u{f700}")
        let previewed = await settle { self.rise(self.silkStrokes(renderer), from: before) != nil }
        XCTAssertTrue(previewed, "the refdes is drawn moved")
        let pads = renderer.residentLineEndpoints(compositeGroup: BoardLayerStyle.compositeGroup(for: top))
        XCTAssertTrue(pads.count == copper.count && zip(pads, copper).allSatisfy { $0.from == $1.from && $0.to == $1.to },
                      "the package and its copper stay")

        try key(36, "\r")
        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let moved = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(moved.packages.first?.position, state.source.packages.first?.position)
        let delta = try XCTUnwrap(moved.packageTexts.first).position - state.source.packageTexts[0].position
        XCTAssertGreaterThan(delta.y, 0)
        XCTAssertEqual(delta.x, 0)
    }

    /// Thirty smashed packages of 32 pads with 240 tracks: Select All, a nudge
    /// and Return. Asking who owns each track end of every package's pads, the
    /// nudge and the commit took over half a minute each in Debug; the budget
    /// is ten times what they take now.
    func testSelectAllNudgeAndCommitOnABusyBoardAreQuick() async throws {
        let state = State(board(packages: 30, padsEach: 32, tracksEach: 8))
        XCTAssertEqual(state.source.tracks.count, 240)
        let (window, renderer, key) = try await mount(state)
        defer { window.close() }
        let before = silkStrokes(renderer)

        let start = Date()
        try key(126, "\u{f700}")
        let previewed = await settle(within: 120) { self.rise(self.silkStrokes(renderer), from: before) != nil }
        XCTAssertTrue(previewed)
        let nudged = Date()
        try key(36, "\r")
        let committed = await settle(within: 120) { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let end = Date()
        XCTAssertLessThan(nudged.timeIntervalSince(start), 5, "the nudge")
        XCTAssertLessThan(end.timeIntervalSince(nudged), 5, "the commit")
        assertMovedWhole(try XCTUnwrap(state.committed.last), from: state.source)
    }
}
#endif
