import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A design whose Channel block is laid out on the board once per instance,
/// for the block layout sync tests. Its pool holds one two-pad resistor
/// whose package draws its refdes on the top silkscreen above its pads.
/// Channel is R1 and R2 in series, R3 beside R2: port IN on R1's pin 1, net
/// MID on R1's pin 2 and R2's and R3's pin 1, port OUT on R2's and R3's pin
/// 2. The top block has `instances` instances of it, I1 to In, each port
/// wired to a top net of its own (IN1, OUT1, …), and with `placeParts` each
/// instance's R1 at (20·k, 0) mm, R2 5 mm right of it and R3 10 mm, by
/// `place_component`.
final class BlockLayoutFixture {
    let root: URL
    let url: URL
    private(set) var archive: HorizontalProjectArchive
    private(set) var project: HorizontalProject
    let channelID = "0c0c0c0c-1111-4222-8333-444455556666"
    private(set) var partID = ""
    /// The package's pads, pin 1's and pin 2's.
    private(set) var padIDs = [String]()
    private(set) var packageTextID = ""
    /// Channel's components, by refdes.
    private(set) var components = [String: String]()
    /// The instances' uuids, I1 first.
    private(set) var instances = [String]()
    /// With `nested`: Sub's resistor, and Sub's instance S1 inside Channel.
    private(set) var subResistor = ""
    private(set) var subInstance = ""

    /// With `nested`, Channel also uses a block Sub, of one resistor RS
    /// placed 5 mm above R1, as S1.
    init(instances count: Int = 2, innerLayers: Int = 0, placeParts: Bool = true, nested: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("block-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("Test.horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: url)

        let poolURL = url.appendingPathComponent("pool")
        var unit = HorizontalPoolItemFactory.newUnit()
        let pins = [HorizontalPoolItemFactory.newUUID(), HorizontalPoolItemFactory.newUUID()]
        unit.pins = [pins[0]: HorizontalUnitPin(id: pins[0], primaryName: "1"),
                     pins[1]: HorizontalUnitPin(id: pins[1], primaryName: "2")]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        let gate = try XCTUnwrap(entity.gates.keys.first)
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = [pins[0]: HorizontalSymbolPin(id: pins[0], position: HorizontalPoint(x: -5_000_000, y: 0), length: 2_500_000),
                       pins[1]: HorizontalSymbolPin(id: pins[1], position: HorizontalPoint(x: 5_000_000, y: 0), length: 2_500_000)]
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shape: HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        padIDs = [HorizontalPoolItemFactory.newUUID(), HorizontalPoolItemFactory.newUUID()]
        for (index, pad) in padIDs.enumerated() {
            package.pads[pad] = HorizontalPad(
                id: pad, name: "\(index + 1)", padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: index == 0 ? -750_000 : 750_000, y: 0), angle: 0, mirrored: false))
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.padMap = [padIDs[0]: HorizontalPartPadMapEntry(gateID: gate, pinID: pins[0]),
                       padIDs[1]: HorizontalPartPadMapEntry(gateID: gate, pinID: pins[1])]
        partID = part.uuid
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: poolURL.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        let packageURL = poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json")
        _ = try HorizontalPoolItemFactory.write(.package(package), to: packageURL)
        // The refdes on the top silkscreen, off centre and turned, so a wrong
        // frame shows.
        packageTextID = HorizontalPoolItemFactory.newUUID()
        var packageJSON = try JSONHelper.loadDictionary(from: packageURL)
        packageJSON["texts"] = [packageTextID: [
            "text": "$RD",
            "placement": ["shift": [300_000, 1_000_000], "angle": 4_096, "mirror": false],
            "layer": HorizontalBoardLayers.topSilkscreen,
            "size": 1_000_000, "width": 150_000, "origin": "center", "font": "simplex",
        ] as JSONDictionary]
        try JSONSerialization.data(withJSONObject: packageJSON).write(to: packageURL)
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)

        try apply([["op": "add_block", "name": "Channel", "id": channelID]])
        for (refdes, x) in [("R1", 10.0), ("R2", 30.0), ("R3", 50.0)] {
            components[refdes] = try XCTUnwrap(try apply([
                ["op": "ensure_component", "refdes": refdes, "part": partID],
                ["op": "place_symbol", "component": refdes, "gate": gate, "x_mm": x, "y_mm": 10],
            ], block: "Channel").first?["component"] as? String)
        }
        try apply([
            ["op": "ensure_net", "name": "IN"],
            ["op": "set_net_port", "net": "IN", "port_direction": "input"],
            ["op": "place_block_port", "net": "IN", "x_mm": -10, "y_mm": 0, "orientation": "left"],
            ["op": "ensure_net", "name": "OUT"],
            ["op": "set_net_port", "net": "OUT", "port_direction": "output"],
            ["op": "place_block_port", "net": "OUT", "x_mm": 50, "y_mm": 0, "orientation": "right"],
            ["op": "ensure_net", "name": "MID"],
            ["op": "connect", "component": "R1", "pin": "1", "net": "IN"],
            ["op": "connect", "component": "R1", "pin": "2", "net": "MID"],
            ["op": "connect", "component": "R2", "pin": "1", "net": "MID"],
            ["op": "connect", "component": "R2", "pin": "2", "net": "OUT"],
            ["op": "connect", "component": "R3", "pin": "1", "net": "MID"],
            ["op": "connect", "component": "R3", "pin": "2", "net": "OUT"],
        ], block: "Channel")

        if nested {
            try apply([["op": "add_block", "name": "Sub"]])
            subResistor = try XCTUnwrap(try apply([
                ["op": "ensure_component", "refdes": "RS", "part": partID],
                ["op": "place_symbol", "component": "RS", "gate": gate, "x_mm": 10, "y_mm": 10],
            ], block: "Sub").first?["component"] as? String)
            subInstance = try XCTUnwrap(try apply([
                ["op": "add_block_instance", "block": "Sub", "refdes": "S1"],
            ], block: "Channel").first?["block_instance"] as? String)
        }
        for index in 1...max(count, 1) {
            let instance = try XCTUnwrap(try apply([
                ["op": "add_block_instance", "block": "Channel", "refdes": "I\(index)"],
            ]).first?["block_instance"] as? String)
            instances.append(instance)
            try apply([
                ["op": "place_block_symbol", "instance": instance, "x_mm": 50, "y_mm": 50 * Double(index)],
                ["op": "connect_block_port", "instance": instance, "port": "IN", "net": "IN\(index)", "create_net": true],
                ["op": "connect_block_port", "instance": instance, "port": "OUT", "net": "OUT\(index)", "create_net": true],
            ])
        }
        if innerLayers > 0 {
            try apply([["op": "set_stackup", "inner_layers": innerLayers]])
        }
        if placeParts {
            for (index, instance) in instances.enumerated() {
                try place(instance, x: 20 * Double(index), y: 0)
                if nested {
                    try apply([["op": "place_component", "component": nestedFlat(instance), "x_mm": 20 * Double(index), "y_mm": 5]])
                }
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The flat uuid of RS in S1 in `instance`.
    func nestedFlat(_ instance: String) -> String {
        HorizontalBlockFlattener.flattenedID([instance, subInstance, subResistor])
    }

    /// The parts of Channel and where `place` puts each from R1.
    static let offsets: [(refdes: String, x: Double)] = [("R1", 0), ("R2", 5), ("R3", 10)]

    /// The flat uuid of `refdes` (R1, R2 or R3) in `instance`, which its package names.
    func flat(_ instance: String, _ refdes: String) -> String {
        HorizontalBlockFlattener.flattenedID([instance, components[refdes] ?? refdes])
    }

    /// Places `instance`'s parts as the instance, turned by `angle` degrees
    /// about R1 at (x, y) mm, puts them; on the bottom, mirrored as a flip
    /// to the bottom mirrors them.
    func place(_ instance: String, x: Double, y: Double, angle: Double = 0, bottom: Bool = false) throws {
        let radians = angle / 180 * Double.pi
        try apply(Self.offsets.map { refdes, offset in
            let dx = bottom ? -offset : offset
            return ["op": "place_component", "component": flat(instance, refdes),
                    "x_mm": x + dx * cos(radians), "y_mm": y + dx * sin(radians), "angle_deg": angle, "bottom": bottom]
        })
    }

    // MARK: - Copper written as Horizon writes it

    /// The board package of `refdes` in `instance`.
    func packageID(_ instance: String, _ refdes: String) throws -> String {
        try package(of: flat(instance, refdes)).id
    }

    /// A track end on pad `number` (1 or 2) of `refdes` in `instance`.
    func padEnd(_ instance: String, _ refdes: String, _ number: Int) throws -> JSONDictionary {
        ["junc": NSNull(), "pad": "\(try packageID(instance, refdes))/\(padIDs[number - 1])"]
    }

    func junctionEnd(_ id: String) -> JSONDictionary {
        ["junc": id, "pad": NSNull()]
    }

    /// Junctions, tracks and vias added to the board file, and the board
    /// loaded again. Vias stand on junctions and take the board's padstack.
    func addCopper(junctions: [String: HorizontalPoint] = [:],
                   tracks: [String: (from: JSONDictionary, to: JSONDictionary, layer: Int)] = [:],
                   vias: [String: String] = [:]) throws {
        var json = try boardJSON()
        var junctionMap = json.dictionaryMap("junctions")
        for (id, point) in junctions {
            junctionMap[id] = ["position": [Int64(point.x), Int64(point.y)]]
        }
        json["junctions"] = junctionMap
        var trackMap = json.dictionaryMap("tracks")
        for (id, track) in tracks {
            trackMap[id] = ["from": track.from, "to": track.to, "layer": track.layer, "width": 200_000,
                            "width_from_net_class": false, "locked": false]
        }
        json["tracks"] = trackMap
        var viaMap = json.dictionaryMap("vias")
        for (id, junction) in vias {
            viaMap[id] = ["junction": junction, "padstack": HorizontalProjectArchive.defaultViaPadstack(poolDefaultVia: nil),
                          "parameter_set": ["via_diameter": 500_000, "hole_diameter": 250_000],
                          "from_rules": false, "source": "local", "locked": false]
        }
        json["vias"] = viaMap
        try putBoard(json)
    }

    /// The match the board as it is makes.
    func match() throws -> HorizontalBlockLayoutMatch {
        HorizontalBlockLayoutMatch(board: try board, instances: try XCTUnwrap(project.flattenedBlock).boardInstances)
    }

    /// An instance's path, which the match keys it by.
    func path(_ index: Int) -> String {
        instances[index].lowercased()
    }

    @discardableResult
    func apply(_ ops: [JSONDictionary], block: String? = nil) throws -> [JSONDictionary] {
        let edited = try HorizontalCanvasProjectEdit.archive(applying: ops, to: archive, in: project, block: block)
        try install(edited.archive)
        return edited.changes
    }

    func install(_ edited: HorizontalProjectArchive) throws {
        archive = edited
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
    }

    var board: HorizontalBoard {
        get throws { try XCTUnwrap(project.board) }
    }

    func boardJSON() throws -> JSONDictionary {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
    }

    func putBoard(_ board: JSONDictionary) throws {
        var edited = archive
        try edited.replaceRegularFileData(relativePath: "board.json", with: JSONSerialization.data(withJSONObject: board))
        try install(edited)
    }

    /// Writes `board` into the project as the canvas does, and loads it again.
    func write(_ board: HorizontalBoard) throws {
        var edited = archive
        _ = try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &edited)
        try install(edited)
    }

    /// The package placed for flat component `componentID`.
    func package(of componentID: String) throws -> HorizontalPlacement {
        try XCTUnwrap(try board.packages.first { $0.componentID?.lowercased() == componentID.lowercased() })
    }
}

extension BlockLayoutFixture {
    /// The project as it stands written to `url`, for a session to open.
    func saveToDisk() throws {
        try archive.write(to: url)
    }
}

/// The MCP dispatcher on a project file, as a client calls it.
final class BlockLayoutDispatchClient {
    let path: String
    private var handle = 0

    init(path: String) throws {
        self.path = path
        let summary = try XCTUnwrap(try result("open_project", ["path": path]) as? JSONDictionary)
        handle = try XCTUnwrap(summary["handle"] as? Int)
    }

    func close() {
        _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#)
    }

    func call(_ method: String, _ params: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = params
        if method != "open_project" {
            params["handle"] = handle
        }
        if ["apply", "sync_block_layout", "autoroute"].contains(method), params["dry_run"] as? Bool != true, params["expected_revision"] == nil {
            let handle = self.handle
            params["expected_revision"] = try HorizontalDispatchSession.shared.perform { try $0.entry(handle: handle).revision }
            params["operation_id"] = UUID().uuidString
        }
        let request: JSONDictionary = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let response = HorizontalDispatch.call(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? JSONDictionary)
    }

    func result(_ method: String, _ params: JSONDictionary = [:]) throws -> Any {
        let response = try call(method, params)
        if let error = response["error"] {
            XCTFail("\(method) failed: \(error)")
        }
        return try XCTUnwrap(response["result"])
    }
}
