#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
#endif
import XCTest
@testable import HorizontalNative

/// A board of many parts in rows, each with pairs of pads, the right pad of
/// each pair routed to the left pad of the next part's through a corner
/// junction, and a via on one corner in eight.
enum ManyPackageBoard {
    static let pitch = 4_000_000.0
    static let top = HorizontalBoardLayers.topCopper

    static func packageID(_ index: Int) -> String { String(format: "aaaaaaaa-0000-4000-8000-%012d", index) }
    static func componentID(_ index: Int) -> String { String(format: "cccccccc-0000-4000-8000-%012d", index) }

    static func origin(_ index: Int, columns: Int) -> HorizontalPoint {
        HorizontalPoint(x: Double(index % columns) * pitch, y: Double(index / columns) * pitch)
    }

    /// The centre of the left (`side` -1) or right (1) pad of pair `pair`.
    static func padCentre(_ index: Int, pair: Int, side: Double, columns: Int) -> HorizontalPoint {
        let at = origin(index, columns: columns)
        return HorizontalPoint(x: at.x + side * 800_000, y: at.y + Double(pair) * 700_000)
    }

    static func board(packages count: Int, columns: Int = 20, padPairs: Int = 1) -> HorizontalBoard {
        let half = 300_000.0
        var packages = [HorizontalPlacement]()
        var pads = [HorizontalPolygon]()
        var padPositions = [String: HorizontalPoint]()
        var lines = [HorizontalSegment]()
        var texts = [HorizontalText]()
        var tracks = [HorizontalSegment]()
        var junctions = [String: HorizontalPoint]()
        var junctionNets = [String: String]()
        var vias = [HorizontalMarker]()
        var nets = [String: HorizontalNetDetails]()

        func netID(_ index: Int, _ pair: Int) -> String? {
            (0..<(count - 1)).contains(index) ? String(format: "eeeeeeee-0000-4000-8000-%012d", index * padPairs + pair) : nil
        }
        for index in 0..<count {
            let id = packageID(index)
            let at = origin(index, columns: columns)
            packages.append(HorizontalPlacement(
                id: id, position: at, angle: 0, mirrored: false, label: "R\(index + 1)", componentID: componentID(index)
            ))
            for pair in 0..<padPairs {
                for (name, side, net) in [(2 * pair + 1, -1.0, netID(index - 1, pair)), (2 * pair + 2, 1.0, netID(index, pair))] {
                    let centre = padCentre(index, pair: pair, side: side, columns: columns)
                    pads.append(HorizontalPolygon(id: "\(id)/pad/\(name)", vertices: [
                        .init(x: centre.x - half, y: centre.y - half), .init(x: centre.x + half, y: centre.y - half),
                        .init(x: centre.x + half, y: centre.y + half), .init(x: centre.x - half, y: centre.y + half),
                    ], layer: top, netID: net))
                    padPositions["\(id)/\(name)"] = centre
                }
            }
            for (name, y) in [("top", 600_000.0), ("bottom", -600_000.0)] {
                lines.append(HorizontalSegment(
                    id: "\(id)/line/\(name)",
                    from: HorizontalPoint(x: at.x - 1_200_000, y: at.y + y), to: HorizontalPoint(x: at.x + 1_200_000, y: at.y + y),
                    width: 150_000, layer: HorizontalBoardLayers.topSilkscreen
                ))
            }
            texts.append(HorizontalText(
                id: "\(id)/text/name", text: "R\(index + 1)",
                position: HorizontalPoint(x: at.x - 600_000, y: at.y + 1_100_000),
                size: 1_000_000, layer: HorizontalBoardLayers.topSilkscreen, origin: .baseline
            ))
        }
        for index in 0..<(count - 1) {
            for pair in 0..<padPairs {
                guard let net = netID(index, pair) else { continue }
                let serial = index * padPairs + pair
                nets[net] = HorizontalNetDetails(id: net, name: "N\(serial)")
                let from = padCentre(index, pair: pair, side: 1, columns: columns)
                let to = padCentre(index + 1, pair: pair, side: -1, columns: columns)
                let corner = HorizontalPoint(x: from.x + 400_000, y: from.y + 1_600_000)
                let junction = String(format: "dddddddd-0000-4000-8000-%012d", serial)
                junctions[junction] = corner
                junctionNets[junction] = net
                tracks.append(HorizontalSegment(
                    id: String(format: "bbbbbbbb-0000-4000-8000-%012d", serial * 2), from: from, to: corner,
                    width: 200_000, layer: top, netID: net, toJunctionID: junction
                ))
                tracks.append(HorizontalSegment(
                    id: String(format: "bbbbbbbb-0000-4000-8000-%012d", serial * 2 + 1), from: corner, to: to,
                    width: 200_000, layer: top, netID: net, fromJunctionID: junction
                ))
                if serial % 8 == 0 {
                    vias.append(HorizontalMarker(
                        id: String(format: "ffffffff-0000-4000-8000-%012d", serial), position: corner, size: 600_000, holeSize: 300_000,
                        layer: nil, connectedLayers: [top, HorizontalBoardLayers.bottomCopper], netID: net
                    ))
                }
            }
        }
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/many-packages.hprj"), uuid: "many", name: "many packages",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: junctions, junctionNetIDs: junctionNets, netDetails: nets,
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias,
            viaHoles: vias.map {
                HorizontalHole(id: HorizontalBoard.viaHoleID(ofVia: $0.id), position: $0.position,
                               diameter: $0.holeSize ?? 300_000, plated: true, netID: $0.netID)
            },
            packages: packages, packagePads: pads, packagePadPositions: padPositions, packageHoles: [], packagePolygons: [],
            packageLines: lines, packageArcs: [], packageTexts: texts, texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    /// What moving every package by `delta` makes of `board`: each package
    /// and its geometry shifted, the track ends on its pads with them, and
    /// the corners and vias left where they are.
    static func movingEveryPackage(of board: HorizontalBoard, by delta: HorizontalPoint) -> HorizontalBoard {
        let padCentres = Set(board.packagePadPositions.values.map(HorizontalCanvasModeSupport.pointKey))
        func onPad(_ point: HorizontalPoint) -> Bool { padCentres.contains(HorizontalCanvasModeSupport.pointKey(point)) }
        var moved = board
        moved.packages = board.packages.map { package in
            var package = package
            package.position = package.position + delta
            return package
        }
        moved.packagePads = board.packagePads.map { HorizontalCanvasModeSupport.shifted($0, by: delta) }
        moved.packagePadPositions = board.packagePadPositions.mapValues { $0 + delta }
        moved.packageLines = board.packageLines.map { HorizontalCanvasModeSupport.shifted($0, by: delta) }
        moved.packageTexts = board.packageTexts.map { HorizontalCanvasModeSupport.shifted($0, by: delta) }
        moved.tracks = board.tracks.map { track in
            var track = track
            if onPad(track.from) { track.from = track.from + delta }
            if onPad(track.to) { track.to = track.to + delta }
            return track
        }
        return moved
    }
}

/// Many packages move together in one pass over the board
/// (`BoardPackageMoves`), and land where each would moved on its own: the
/// package and its geometry shifted, the track ends on its pads carried, the
/// rest of the copper left. A move's commit used to read every track and
/// junction again for each package it moved.
final class BoardManyPackageMoveTests: XCTestCase {
    private let delta = HorizontalPoint(x: 1_250_000, y: -2_500_000)

    private func assertSameGeometry(_ lhs: HorizontalBoard, _ rhs: HorizontalBoard, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.packages, rhs.packages, file: file, line: line)
        XCTAssertEqual(lhs.packagePads, rhs.packagePads, file: file, line: line)
        XCTAssertEqual(lhs.packagePadPositions, rhs.packagePadPositions, file: file, line: line)
        XCTAssertEqual(lhs.packageLines, rhs.packageLines, file: file, line: line)
        XCTAssertEqual(lhs.packageTexts, rhs.packageTexts, file: file, line: line)
        XCTAssertEqual(lhs.tracks, rhs.tracks, file: file, line: line)
        XCTAssertEqual(lhs.junctions, rhs.junctions, file: file, line: line)
        XCTAssertEqual(lhs.junctionNetIDs, rhs.junctionNetIDs, file: file, line: line)
        XCTAssertEqual(lhs.vias, rhs.vias, file: file, line: line)
        XCTAssertEqual(lhs.viaHoles, rhs.viaHoles, file: file, line: line)
    }

    func testPackagesMovedTogetherTakeTheirPadsAndTheTrackEndsOnThem() {
        let board = ManyPackageBoard.board(packages: 60, columns: 8, padPairs: 2)
        var moved = board
        let passes = BoardPackageMoves.passes
        BoardPackageMoves.apply(Set(board.packages.map(\.id)), by: delta, to: &moved)

        XCTAssertEqual(BoardPackageMoves.passes - passes, 1, "the tracks and junctions are read once for all sixty")
        assertSameGeometry(moved, ManyPackageBoard.movingEveryPackage(of: board, by: delta))
    }

    func testPackagesMovedTogetherLandWhereEachMovedAloneLands() {
        let board = ManyPackageBoard.board(packages: 40, columns: 8, padPairs: 2)
        let ids = board.packages.prefix(25).map(\.id)
        var together = board
        BoardPackageMoves.apply(Set(ids), by: delta, to: &together)
        var oneByOne = board
        for id in ids {
            BoardPackageMoves.apply([id], by: delta, to: &oneByOne)
        }

        assertSameGeometry(together, oneByOne)
        XCTAssertEqual(together.packages[30].position, board.packages[30].position, "a package not named stays")
    }

    /// A row of parts moved along itself by its own pitch puts each part's
    /// pad where the next one's stood. An end the first part carried there
    /// stays with the first, as the move's preview draws it; taken package
    /// by package, the next part, not yet moved, carried it on again.
    func testAnEndCarriedOntoTheNextPackagesPadIsNotCarriedAgain() {
        var board = ManyPackageBoard.board(packages: 3, columns: 3, padPairs: 1)
        // One net for every pad, so an end follows whichever pad it is on.
        board.packagePads = board.packagePads.map { pad in
            var pad = pad
            pad.netID = "n"
            return pad
        }
        let from = ManyPackageBoard.padCentre(0, pair: 0, side: 1, columns: 3)
        let free = HorizontalPoint(x: from.x, y: from.y - 3_000_000)
        board.tracks = [HorizontalSegment(id: "t", from: from, to: free, width: 200_000, layer: ManyPackageBoard.top, netID: "n")]
        board.junctions = [:]
        board.junctionNetIDs = [:]
        let step = HorizontalPoint(x: ManyPackageBoard.pitch, y: 0)
        XCTAssertEqual(from + step, ManyPackageBoard.padCentre(1, pair: 0, side: 1, columns: 3), "the next part's pad is one step on")

        BoardPackageMoves.apply(Set(board.packages.map(\.id)), by: step, to: &board)

        XCTAssertEqual(board.tracks[0].from, from + step, "carried once, by the part it is on")
        XCTAssertEqual(board.tracks[0].to, free)
    }

    func testAJunctionOnAPadGoesWithItAndAFixedPackageStays() {
        var board = ManyPackageBoard.board(packages: 4, columns: 4, padPairs: 1)
        let pad = ManyPackageBoard.padCentre(1, pair: 0, side: 1, columns: 4)
        board.junctions["on-pad"] = pad
        board.packages[2].fixed = true
        let fixedPad = ManyPackageBoard.padCentre(2, pair: 0, side: -1, columns: 4)

        BoardPackageMoves.apply(Set(board.packages.map(\.id)), by: delta, to: &board)

        XCTAssertEqual(board.junctions["on-pad"], pad + delta)
        XCTAssertEqual(board.packages[2].position, ManyPackageBoard.origin(2, columns: 4))
        XCTAssertEqual(board.packagePadPositions["\(ManyPackageBoard.packageID(2))/1"], fixedPad)
        XCTAssertEqual(board.tracks[3].to, fixedPad, "and the end on its pad with it")
    }

    /// The junctions a move lands on one another fold into one at each point,
    /// whether the points are folded in one call or a call each.
    func testJunctionsFoldedAtManyPointsInOneCallFoldAsOneCallEachDoes() {
        var board = ManyPackageBoard.board(packages: 12, columns: 4, padPairs: 1)
        // A second junction on every other corner, some with a net and some
        // without, for the first to fold in.
        var places = [(point: HorizontalPoint, preferredID: String, netID: String?)]()
        for (offset, id) in board.junctions.keys.sorted().enumerated() {
            guard let point = board.junctions[id] else { continue }
            if offset.isMultiple(of: 2) {
                board.junctions["extra-\(offset)"] = point
                if offset.isMultiple(of: 4) {
                    board.junctionNetIDs["extra-\(offset)"] = board.junctionNetIDs[id]
                }
                board.tracks.append(HorizontalSegment(
                    id: "extra-track-\(offset)", from: point, to: HorizontalPoint(x: point.x, y: point.y + 500_000),
                    width: 200_000, layer: ManyPackageBoard.top, netID: board.junctionNetIDs[id], fromJunctionID: "extra-\(offset)"
                ))
            }
            places.append((point, id, offset.isMultiple(of: 3) ? nil : "fallback"))
        }

        var together = board
        BoardTrackRouting.mergeJunctions(at: places, board: &together)
        var oneByOne = board
        for place in places {
            BoardTrackRouting.mergeJunctions(
                at: place.point, preferredID: place.preferredID,
                netID: oneByOne.junctionNetIDs[place.preferredID] ?? place.netID, board: &oneByOne
            )
        }

        XCTAssertEqual(together.junctions, oneByOne.junctions)
        XCTAssertEqual(together.junctionNetIDs, oneByOne.junctionNetIDs)
        XCTAssertEqual(together.tracks, oneByOne.tracks)
        XCTAssertEqual(together.junctions.count, 11, "one junction left at each corner")
    }

    func testObjectPositionsFindTheFirstOfAnIDWhateverItsCase() {
        var board = ManyPackageBoard.board(packages: 6, columns: 3, padPairs: 1)
        board.vias.append(board.vias[0])
        var positions = BoardObjectPositions(of: board)

        XCTAssertEqual(positions.index(of: board.tracks[4].id.uppercased(), in: \.tracks), 4)
        XCTAssertEqual(positions.index(of: board.vias[0].id, in: \.vias), 0, "the first of two with one id")
        XCTAssertNil(positions.index(of: "missing", in: \.tracks))
        let junction = board.junctions.keys.sorted()[1]
        XCTAssertEqual(positions.junction(junction.uppercased())?.id, junction)
        XCTAssertEqual(positions.junction(junction)?.point, board.junctions[junction])
        XCTAssertNil(positions.junction("missing"))
        XCTAssertTrue(positions.hasMovableConnection(at: board.vias[0].position))
        XCTAssertTrue(positions.hasMovableConnection(at: board.junctions[junction] ?? .zero))
        XCTAssertFalse(positions.hasMovableConnection(at: ManyPackageBoard.padCentre(0, pair: 0, side: 1, columns: 3)))
    }
}

#if os(macOS)
/// A board canvas in a window over a board of many packages, for the tests
/// that drive it through its keys, its commands and the inspector's edits.
@MainActor
final class ManyPackageCanvas: ObservableObject {
    /// An inspector edit for the canvas to make.
    @Published var command: HorizontalSelectionPropertyChangeCommand?
    let source: HorizontalBoard
    /// Each board the canvas handed back; the last is the one it shows.
    var committed: [HorizontalBoard] = []
    /// With `hearsRestores`, each board the canvas put back (an undo, a
    /// redo), which then are not among `committed`.
    var restored: [HorizontalBoard] = []
    var hearsRestores = false
    var actions: HorizontalCanvasCommandActions?
    let undo = UndoManager()
    let toolSettings = HorizontalBoardToolSettings()
    private var window: NSWindow?
    private var handle: ((NSEvent) -> NSEvent?)?

    init(_ board: HorizontalBoard) {
        source = board
    }

    private struct Pane: View {
        @ObservedObject var canvas: ManyPackageCanvas
        @State private var board: HorizontalBoard
        @State private var viewport = CanvasViewport()
        init(canvas: ManyPackageCanvas) {
            self.canvas = canvas
            _board = State(initialValue: canvas.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: canvas.undo,
                onBoardChange: { canvas.committed.append($0); board = $0 },
                onBoardRestore: canvas.hearsRestores ? { canvas.restored.append($0); board = $0 } : nil,
                onCanvasCommandActionsChange: { canvas.actions = $0 },
                selectionPropertyChangeCommand: canvas.command,
                toolSettings: canvas.toolSettings)
        }
    }

    func settle(_ seconds: TimeInterval = 20, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    /// Puts the canvas in a window and waits for it to take commands.
    func mount() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Pane(canvas: self)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        self.window = window
        let mounted = await settle { self.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
    }

    func close() {
        window?.close()
    }

    /// Sends the canvas a key press.
    func key(_ code: UInt16, _ characters: String) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        _ = try XCTUnwrap(handle)(event)
    }

    /// Selects the packages of the first `count` components and waits for
    /// the canvas to have them.
    func selectComponents(_ count: Int) async {
        XCTAssertEqual(actions?.selectComponents?(Set((0..<count).map(ManyPackageBoard.componentID))), true)
        let selected = await settle(120) { self.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
    }

    /// How long the main thread stays busy from now: until three sleeps of a
    /// millisecond in a row each come back within a few.
    func untilIdle() async -> TimeInterval {
        let start = Date()
        var lastBusy = start
        var quiet = 0
        while quiet < 3, Date().timeIntervalSince(start) < 120 {
            let before = Date()
            try? await Task.sleep(for: .milliseconds(1))
            if Date().timeIntervalSince(before) < 0.012 {
                quiet += 1
            } else {
                quiet = 0
                lastBusy = Date()
            }
        }
        return lastBusy.timeIntervalSince(start)
    }
}

/// The board canvas's own move of many packages, through its keys: the
/// commit moves them all in one pass over the board, to where each belongs,
/// as one undo step.
@MainActor
final class BoardManyPackageMoveCanvasTests: XCTestCase {
    func testCommittingAMoveOfManyPackagesMovesThemInOnePassAndOneUndoStep() async throws {
        let count = 240
        let source = ManyPackageBoard.board(packages: count, padPairs: 2)
        let canvas = ManyPackageCanvas(source)
        try await canvas.mount()
        defer { canvas.close() }
        await canvas.selectComponents(count)

        try canvas.key(126, "\u{f700}")   // up: a keyboard move
        let moving = await canvas.settle { canvas.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        let passes = BoardPackageMoves.passes
        try canvas.key(36, "\r")
        let committed = await canvas.settle { canvas.committed.count == 1 }
        XCTAssertTrue(committed)
        XCTAssertEqual(BoardPackageMoves.passes - passes, 1, "the commit reads the board's tracks and junctions once, not once a package")

        let moved = try XCTUnwrap(canvas.committed.last)
        let delta = try XCTUnwrap(moved.packages.first).position - source.packages[0].position
        XCTAssertEqual(delta.x, 0)
        XCTAssertGreaterThan(delta.y, 0, "up a grid step")
        let expected = ManyPackageBoard.movingEveryPackage(of: source, by: delta)
        XCTAssertEqual(moved.packages.map(\.position), expected.packages.map(\.position))
        XCTAssertEqual(moved.packagePads.map(\.vertices), expected.packagePads.map(\.vertices))
        XCTAssertEqual(moved.packagePadPositions, expected.packagePadPositions)
        XCTAssertEqual(moved.packageLines.map(\.from), expected.packageLines.map(\.from))
        XCTAssertEqual(moved.packageTexts.map(\.position), expected.packageTexts.map(\.position))
        XCTAssertEqual(moved.tracks.map(\.from), expected.tracks.map(\.from), "the ends on the pads go with them")
        XCTAssertEqual(moved.tracks.map(\.to), expected.tracks.map(\.to))
        XCTAssertEqual(moved.junctions, source.junctions, "and the corners stay")
        XCTAssertEqual(moved.vias.map(\.position), source.vias.map(\.position))

        XCTAssertTrue(canvas.undo.canUndo)
        canvas.undo.undo()
        let undone = await canvas.settle { canvas.committed.count == 2 }
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(canvas.committed.last)
        XCTAssertEqual(restored.packages.map(\.position), source.packages.map(\.position))
        XCTAssertEqual(restored.tracks.map(\.from), source.tracks.map(\.from))
        XCTAssertFalse(canvas.undo.canUndo, "the whole move was one step")
    }

    /// Not a test of behaviour: prints how long a move of every package
    /// takes to commit, for each count in `HORIZONTAL_MOVE_TIMING_COUNTS`
    /// (say "400,800,1600"; twice the parts should take twice the time).
    /// `HORIZONTAL_MOVE_TIMING_PAD_PAIRS` sets the pads on each part,
    /// `HORIZONTAL_MOVE_TIMING_SELECTED` how many of the parts move (all of
    /// them, left out), and `HORIZONTAL_MOVE_TIMING_SELECT_ALL` moves the
    /// tracks, junctions and vias with the parts. With `HORIZON_PROFILE=1`
    /// the canvas prints the stages of each commit as well.
    func testCommitTimingOfAMoveOfEveryPackage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let counts = environment["HORIZONTAL_MOVE_TIMING_COUNTS"]?.split(separator: ",").compactMap({ Int($0) }),
              !counts.isEmpty else {
            throw XCTSkip("set HORIZONTAL_MOVE_TIMING_COUNTS to time a commit")
        }
        let padPairs = environment["HORIZONTAL_MOVE_TIMING_PAD_PAIRS"].flatMap { Int($0) } ?? 1
        for count in counts {
            let canvas = ManyPackageCanvas(ManyPackageBoard.board(packages: count, padPairs: padPairs))
            try await canvas.mount()
            defer { canvas.close() }
            _ = await canvas.untilIdle()
            if environment["HORIZONTAL_MOVE_TIMING_SELECT_ALL"] != nil {
                canvas.actions?.dispatch(.selectAll)
                let selected = await canvas.settle(120) { canvas.actions?.canMoveSelection == true }
                XCTAssertTrue(selected)
            } else {
                await canvas.selectComponents(min(environment["HORIZONTAL_MOVE_TIMING_SELECTED"].flatMap { Int($0) } ?? count, count))
            }
            _ = await canvas.untilIdle()

            var clock = Date()
            try canvas.key(126, "\u{f700}")
            let begin = Date().timeIntervalSince(clock)
            let moving = await canvas.settle(120) { canvas.actions?.canCommitInteraction == true }
            XCTAssertTrue(moving)
            _ = await canvas.untilIdle()

            clock = Date()
            try canvas.key(36, "\r")
            let commit = Date().timeIntervalSince(clock)
            let committed = await canvas.settle(120) { canvas.committed.count == 1 }
            XCTAssertTrue(committed)
            let after = await canvas.untilIdle()
            let total = Date().timeIntervalSince(clock)
            let board = canvas.source
            print(String(
                format: "MOVE TIMING packages %4d pads %5d tracks %5d  begin %7.1f ms  commit %8.1f ms  busy after %8.1f ms  commit to idle %8.1f ms",
                count, board.packagePads.count, board.tracks.count, begin * 1000, commit * 1000, after * 1000, total * 1000
            ))
        }
    }
}
#endif
