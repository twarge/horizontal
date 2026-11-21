import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A blank board with R1 at (10, 10) mm and R2 at (40, 10) mm, two-pin
/// resistors with a top pad for each pin: pin 1 of each on +3V3, R1's pin 2
/// on +5V, R2's on none. Copper goes on through the edit vocabulary, as the
/// app's own controls put it on, so a test lays out the vias it needs pinned
/// or not (`place_via`'s `net_pinned`).
final class PinnedViaFixture {
    let root: URL
    let url: URL
    private(set) var project: HorizontalProject
    private(set) var archive: HorizontalProjectArchive

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-vias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: url)
        let part = try Self.fabricateResistor(poolURL: url.appendingPathComponent("pool"))
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
        try edit([
            ["op": "ensure_component", "refdes": "R1", "part": part],
            ["op": "ensure_component", "refdes": "R2", "part": part],
            ["op": "ensure_net", "name": "+3V3", "is_power": true],
            ["op": "ensure_net", "name": "+5V", "is_power": true],
            ["op": "connect", "component": "R1", "pin": "1", "net": "+3V3"],
            ["op": "connect", "component": "R2", "pin": "1", "net": "+3V3"],
            ["op": "connect", "component": "R1", "pin": "2", "net": "+5V"],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": "R2", "x_mm": 40, "y_mm": 10],
        ])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A two-pin resistor with a top-copper pad for each pin, in the
    /// project's pool. Returns the part.
    private static func fabricateResistor(poolURL: URL) throws -> String {
        let pin1 = HorizontalPoolItemFactory.newUUID(), pin2 = HorizontalPoolItemFactory.newUUID()
        var unit = HorizontalPoolItemFactory.newUnit()
        unit.pins = [pin1: HorizontalUnitPin(id: pin1, primaryName: "1"), pin2: HorizontalUnitPin(id: pin2, primaryName: "2")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let gate = try XCTUnwrap(entity.gates.keys.first)
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shape: HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        var padIDs = [String]()
        for (index, name) in ["1", "2"].enumerated() {
            let pad = HorizontalPoolItemFactory.newUUID()
            padIDs.append(pad)
            package.pads[pad] = HorizontalPad(
                id: pad, name: name, padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(
                    shift: HorizontalPoint(x: Double(index * 1_600_000 - 800_000), y: 0), angle: 0, mirrored: false))
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.padMap = [padIDs[0]: HorizontalPartPadMapEntry(gateID: gate, pinID: pin1),
                       padIDs[1]: HorizontalPartPadMapEntry(gateID: gate, pinID: pin2)]
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        return part.uuid
    }

    // MARK: - Editing

    /// One batch of ops, one archive edit, the project read again.
    @discardableResult
    func edit(_ ops: [JSONDictionary]) throws -> [JSONDictionary] {
        let edited = try HorizontalCanvasProjectEdit.archive(applying: ops, to: archive, in: project)
        archive = edited.archive
        try reload()
        return edited.changes
    }

    func reload() throws {
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
    }

    /// The board canvas's commit and save: the nets re-derived, written
    /// through the applicator the document saves with, and read again.
    func commit(_ board: HorizontalBoard) throws {
        let resolved = HorizontalBoardConnectivity.recompute(board)
        try HorizontalProjectJSONApplicator.apply(board: resolved, in: project, to: &archive)
        try reload()
    }

    /// Pins the via at (`x`, `y`) mm to `net`, whatever net its copper is on:
    /// the conflict a pin moved to another net in the schematic leaves a
    /// pinned via in. No op writes one: `place_via` refuses a point where
    /// another net's junction stands. Written as the canvas saves a board.
    func repin(viaAt x: Double, _ y: Double, to net: String) throws {
        var board = try board
        let point = HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
        let index = try XCTUnwrap(board.vias.firstIndex { $0.position == point }, "no via at (\(x), \(y))")
        board.vias[index].netSetID = try self.net(net)
        try commit(board)
    }

    /// The project as it is now, on disk, for the dispatch layer to open.
    func writeToDisk() throws {
        try archive.write(to: url)
    }

    // MARK: - Reading

    var board: HorizontalBoard {
        get throws { try XCTUnwrap(project.board) }
    }

    func net(_ name: String) throws -> String {
        try XCTUnwrap(project.board?.netDetails.values.first { $0.name == name }?.id).lowercased()
    }

    func boardFile() throws -> JSONDictionary {
        let name = try XCTUnwrap(project.boardFilename)
        let data = try XCTUnwrap(archive.regularFileData(relativePath: name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    func viaEntries() throws -> [String: JSONDictionary] {
        try boardFile().dictionaryMap("vias")
    }

    // MARK: - Copper

    /// A via at (`x`, `y`) mm on `net`, pinned to it or not.
    static func via(_ x: Double, _ y: Double, _ net: String, pinned: Bool) -> JSONDictionary {
        ["op": "place_via", "x_mm": x, "y_mm": y, "net": net, "net_pinned": pinned]
    }

    /// A top-copper track from a pad to a point.
    static func track(from component: String, pad: String, to x: Double, _ y: Double) -> JSONDictionary {
        ["op": "place_track", "from": ["component": component, "pad": pad], "to": ["x_mm": x, "y_mm": y],
         "layer": 0, "width_mm": 0.25]
    }

    /// A track between two points, on `layer` (0 top, -100 bottom). `net`
    /// for one whose ends name none; the file stores no net on a track.
    static func track(_ from: (Double, Double), _ to: (Double, Double), layer: Int, net: String? = nil) -> JSONDictionary {
        var op: JSONDictionary = ["op": "place_track", "from": ["x_mm": from.0, "y_mm": from.1], "to": ["x_mm": to.0, "y_mm": to.1],
                                  "layer": layer, "width_mm": 0.25]
        if let net { op["net"] = net }
        return op
    }

    /// A top-copper track from a point to a pad: the last leg of a route,
    /// up through a via, since the pads are on top only.
    static func track(_ from: (Double, Double), toComponent component: String, pad: String) -> JSONDictionary {
        ["op": "place_track", "from": ["x_mm": from.0, "y_mm": from.1], "to": ["component": component, "pad": pad],
         "layer": 0, "width_mm": 0.25]
    }

    typealias ViaSpec = (x: Double, y: Double, net: String, pinned: Bool)

    /// R1's pad 1 to R2's pad 1 the way a route through vias goes: down
    /// through `down`, along the bottom, up through `up` and on top to the pad.
    static func route(down: ViaSpec, up: ViaSpec) -> [JSONDictionary] {
        [
            track(from: "R1", pad: "1", to: down.x, down.y),
            via(down.x, down.y, down.net, pinned: down.pinned),
            track((down.x, down.y), (up.x, up.y), layer: -100),
            via(up.x, up.y, up.net, pinned: up.pinned),
            track((up.x, up.y), toComponent: "R2", pad: "1"),
        ]
    }
}
