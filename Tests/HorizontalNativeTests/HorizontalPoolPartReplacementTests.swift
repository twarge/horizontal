import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The Pools pane's Replace (126), Horizon's Assign Part: with components
/// selected the list shows only the parts for the entity they share, and
/// Replace gives every one of them the part with `set_part`, keeping their
/// connections, as one edit the document adopts. A part in another package
/// is given to a component unless copper ends on its pads, which the new
/// footprint wouldn't have.
final class HorizontalPoolPartReplacementTests: XCTestCase {
    // MARK: - The compatibility rule

    private func block(_ components: [String: (refdes: String, entity: String, part: String?)]) -> JSONDictionary {
        ["components": components.mapValues { component -> JSONDictionary in
            var json: JSONDictionary = ["refdes": component.refdes, "entity": component.entity]
            if let part = component.part { json["part"] = part }
            return json
        } as JSONDictionary]
    }

    private func partItem(_ uuid: String, name: String, entity: String, package: String = "pkg-0603",
                          isBasePart: Bool = false, parametric: [String: String] = [:]) -> HorizontalPoolLibraryItem {
        HorizontalPoolLibraryItem(
            id: "/pool|part|\(uuid)", uuid: uuid, name: name, detail: "Yageo", tags: "resistor", category: .part,
            poolName: "Pool", poolURL: URL(fileURLWithPath: "/pool"), url: URL(fileURLWithPath: "/pool/parts/\(uuid).json"),
            manufacturer: "Yageo", parametric: parametric, packageID: package, isBasePart: isBasePart, partEntityID: entity
        )
    }

    private let components: [String: (refdes: String, entity: String, part: String?)] = [
        "c-r12": ("R12", "e-res", "p-10k"),
        "c-r2": ("R2", "e-res", "p-10k"),
        "c-c1": ("C1", "e-cap", "p-100n"),
    ]

    func testTheSelectionsPartsAreThoseForTheEntityItShares() throws {
        let replacement = try XCTUnwrap(HorizontalPartReplacement(componentIDs: ["C-R12", "c-r2", "c-missing"], block: block(components)))
        XCTAssertEqual(replacement.targets.map(\.refdes), ["R2", "R12"], "in refdes order, naturally, and only what the block has")
        XCTAssertEqual(replacement.entityID, "e-res")
        XCTAssertNil(replacement.problem)
        XCTAssertEqual(replacement.refdesList, "R2, R12")
        XCTAssertNil(replacement.blockID, "the top block")

        let other = partItem("p-22k", name: "RC0603-22K", entity: "e-res")
        XCTAssertTrue(replacement.isCompatible(other))
        XCTAssertFalse(replacement.isCompatible(partItem("p-100n", name: "CL10B104", entity: "e-cap")), "another entity's part")
        XCTAssertFalse(replacement.isCompatible(partItem("p-base", name: "Base", entity: "e-res", isBasePart: true)),
                       "a base part, which Horizon's part browser leaves out")
        var package = other
        package.category = .package
        XCTAssertFalse(replacement.isCompatible(package), "only parts")

        // Replace sets the part on each component not already on it.
        XCTAssertNil(replacement.refusal(for: other))
        XCTAssertEqual(replacement.operations(partID: "P-22K").map { $0.string("component") }, ["c-r2", "c-r12"])
        XCTAssertEqual(replacement.operations(partID: "p-22k").first?.string("op"), "set_part")
        XCTAssertEqual(replacement.operations(partID: "p-22k").first?.string("part"), "p-22k")
        let current = partItem("p-10k", name: "RC0603-10K", entity: "e-res")
        XCTAssertEqual(replacement.refusal(for: current), "R2, R12 already use “RC0603-10K”.")
        XCTAssertTrue(replacement.operations(partID: "p-10k").isEmpty)
        XCTAssertTrue(replacement.refusal(for: partItem("p-100n", name: "CL10B104", entity: "e-cap"))?.contains("another entity") == true)
    }

    func testComponentsOnDifferentEntitiesHaveNoPartInCommon() throws {
        let replacement = try XCTUnwrap(HorizontalPartReplacement(componentIDs: ["c-r12", "c-c1"], block: block(components)))
        XCTAssertNil(replacement.entityID)
        XCTAssertEqual(replacement.problem,
                       "C1, R12 are on different entities, so no part fits them all. Select components of one kind to replace them together.")
        XCTAssertFalse(replacement.isCompatible(partItem("p-22k", name: "RC0603-22K", entity: "e-res")))
        XCTAssertFalse(replacement.isCompatible(partItem("p-100n", name: "CL10B104", entity: "e-cap")))
        XCTAssertEqual(replacement.refusal(for: partItem("p-22k", name: "RC0603-22K", entity: "e-res")), replacement.problem)
        XCTAssertNil(HorizontalPartReplacement(componentIDs: ["c-none"], block: block(components)), "nothing the block has")
        XCTAssertNil(HorizontalPartReplacement(componentIDs: [], block: block(components)))
    }

    /// The list while replacing: the parts that fit, narrowed by the search
    /// as before. Other kinds list as they did.
    func testTheListShowsOnlyThePartsThatFitAndTheSearchStillNarrowsThem() throws {
        let replacement = try XCTUnwrap(HorizontalPartReplacement(componentIDs: ["c-r12"], block: block(components)))
        var package = partItem("pkg-0603", name: "R0603", entity: "")
        package.category = .package
        let items = [
            partItem("p-10k", name: "RC0603-10K", entity: "e-res"),
            partItem("p-22k", name: "RC0603-22K", entity: "e-res"),
            partItem("p-100n", name: "CL10B104", entity: "e-cap"),
            package,
        ]
        func names(_ category: HorizontalPoolItemCategory, _ search: String, _ replacement: HorizontalPartReplacement?) -> [String] {
            HorizontalPoolBrowserView.listed(items, category: category, search: search, replacement: replacement).map(\.name)
        }
        XCTAssertEqual(names(.part, "", replacement), ["RC0603-10K", "RC0603-22K"])
        XCTAssertEqual(names(.part, "22k", replacement), ["RC0603-22K"])
        XCTAssertEqual(names(.part, "", nil), ["RC0603-10K", "RC0603-22K", "CL10B104"], "no selection, every part")
        XCTAssertEqual(names(.package, "", replacement), ["R0603"], "the filter is the parts'")
    }

    func testCopperOnAComponentsPadsIsWhatStopsAPackageChange() throws {
        let replacement = try XCTUnwrap(HorizontalPartReplacement(componentIDs: ["c-r12", "c-r2"], block: block(components)))
        let board: JSONDictionary = [
            "packages": [
                "bp-r12": ["component": "c-r12"] as JSONDictionary,
                "bp-r2": ["component": "c-r2"] as JSONDictionary,
            ] as JSONDictionary,
            "tracks": [
                "t1": ["from": ["pad": "bp-r12/pad-1"] as JSONDictionary, "to": ["junc": "j1"] as JSONDictionary] as JSONDictionary,
            ] as JSONDictionary,
        ]
        XCTAssertEqual(replacement.routedTargets(board: board).map(\.refdes), ["R12"])
        let packages = ["p-10k": "pkg-0603"]
        func refusal(_ newPackage: String) -> String? {
            replacement.packageChangeRefusal(newPackageID: newPackage, partName: "RC0805-22K", currentPackageID: { packages[$0] },
                                             board: board, packageName: { ["pkg-0603": "R0603", "pkg-0805": "R0805"][$0] ?? $0 })
        }
        XCTAssertNil(refusal("pkg-0603"), "the same package keeps every pad")
        XCTAssertEqual(refusal("pkg-0805"),
                       "“RC0805-22K” comes in R0805, not R0603, and R12 has tracks on its pads, which the new footprint doesn't have. "
                       + "Nothing was changed: remove those tracks first, or choose a part in R0603.")
        // Nothing routed: the board takes the new package from the part.
        var unrouted = board
        unrouted["tracks"] = [String: Any]()
        XCTAssertNil(replacement.packageChangeRefusal(newPackageID: "pkg-0805", partName: "x", currentPackageID: { packages[$0] },
                                                      board: unrouted, packageName: { $0 }))
    }

    // MARK: - Replace through the editor, as the window applies it

    private struct SharedEntityParts {
        var items: [JSONDictionary]
        var entity: String
        var small: String
        var smallAlternative: String
        var large: String
        var smallPackage: String
        var largePackage: String
        var smallPads: Set<String>
        var largePads: Set<String>
    }

    /// A two-pin entity with three parts: two in one package, one in another
    /// whose pads are other pads, as two footprints' are.
    private func sharedEntityParts() -> SharedEntityParts {
        let names = ["A", "B"]
        let pins = names.map { _ in UUID().uuidString.lowercased() }
        var unit = HorizontalPoolItemFactory.newUnit()
        for i in pins.indices {
            unit.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: names[i], direction: .passive)
        }
        let entity = HorizontalPoolItemFactory.newEntity(for: unit)
        let gate = entity.gates.keys.first!
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        for i in pins.indices {
            symbol.pins[pins[i]] = HorizontalSymbolPin(id: pins[i], position: HorizontalPoint(x: 0, y: -Double(i) * 2_540_000),
                                                       length: 2_540_000, orientation: .left)
        }
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = UUID().uuidString.lowercased()
        padstack.shapes[shape] = HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])
        func package(_ name: String, pitch: Double) -> HorizontalPoolPackage {
            var package = HorizontalPoolItemFactory.newPackage()
            package.name = name
            for i in names.indices {
                let pad = UUID().uuidString.lowercased()
                package.pads[pad] = HorizontalPad(id: pad, name: String(i + 1), padstackID: padstack.uuid,
                    placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: Double(i) * pitch, y: 0), angle: 0, mirrored: false))
            }
            return package
        }
        let small = package("R0603", pitch: 1_600_000)
        let large = package("R0805", pitch: 2_000_000)
        func part(_ mpn: String, value: String, in package: HorizontalPoolPackage) -> HorizontalPoolPartItem {
            var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
            for (pad, info) in package.pads {
                part.padMap[pad] = HorizontalPartPadMapEntry(gateID: gate, pinID: pins[Int(info.name)! - 1])
            }
            part.attributes[.mpn] = HorizontalPartAttribute(value: mpn)
            part.attributes[.value] = HorizontalPartAttribute(value: value)
            return part
        }
        let tenK = part("RC0603-10K", value: "10k", in: small)
        let twentyTwoK = part("RC0603-22K", value: "22k", in: small)
        let large22K = part("RC0805-22K", value: "22k", in: large)
        return SharedEntityParts(
            items: [unit.json(), entity.json(), symbol.json(), padstack.json(), small.json(), large.json(),
                    tenK.json(), twentyTwoK.json(), large22K.json()],
            entity: entity.uuid, small: tenK.uuid, smallAlternative: twentyTwoK.uuid, large: large22K.uuid,
            smallPackage: small.uuid, largePackage: large.uuid,
            smallPads: Set(small.pads.keys.map { $0.lowercased() }), largePads: Set(large.pads.keys.map { $0.lowercased() })
        )
    }

    func testReplaceGivesEveryComponentThePartKeepsItsConnectionsAndTheBoardItsNewPackage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = HorizontalDispatchSession()
        let handle = try session.open(url: url).handle
        func apply(_ ops: [JSONDictionary], _ extra: JSONDictionary = [:]) throws {
            let entry = try session.entry(handle: handle)
            var params = extra.merging(["ops": ops]) { new, _ in new }
            params["handle"] = handle
            params["expected_revision"] = entry.revision
            params["operation_id"] = UUID().uuidString
            let response = try JSONHelper.loadDictionary(from: Data(HorizontalDispatch.serialize(HorizontalDispatch.call(
                ["jsonrpc": "2.0", "id": 1, "method": "apply", "params": params], in: session), pretty: false).utf8))
            XCTAssertNil(response["error"], "\(response)")
        }
        let parts = sharedEntityParts()
        try apply([
            ["op": "ensure_component", "refdes": "R1", "part": parts.small],
            ["op": "ensure_component", "refdes": "R2", "part": parts.small],
            ["op": "connect", "component": "R1", "pin": "A", "net": "IN", "create_net": true],
            ["op": "connect", "component": "R1", "pin": "B", "net": "MID", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "A", "net": "MID"],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": "R2", "x_mm": 20, "y_mm": 10],
        ], ["pool_items": parts.items])

        var archive = try HorizontalProjectArchive.completeProject(from: url)
        var project = try HorizontalProject.load(from: url)
        func componentIDs() throws -> [String: String] {
            let store = HorizontalArchiveFileStore(archive: archive, baseURL: project.baseURL)
            let data = try XCTUnwrap(try store.read(project.baseURL.appendingPathComponent(try XCTUnwrap(project.blockFilename))))
            return Dictionary(uniqueKeysWithValues: try JSONHelper.loadDictionary(from: data).dictionaryMap("components")
                .map { ($0.value.string("refdes") ?? "", $0.key.lowercased()) })
        }
        let ids = try componentIDs()
        let replacement = try XCTUnwrap(HorizontalPartReplacement.current(
            componentIDs: [try XCTUnwrap(ids["R1"]), try XCTUnwrap(ids["R2"])], archive: archive, project: project))
        XCTAssertEqual(replacement.targets.map(\.refdes), ["R1", "R2"])
        XCTAssertEqual(replacement.entityID, parts.entity.lowercased())

        // The project pool's parts, as the Pools pane lists them.
        let poolURL = project.baseURL.appendingPathComponent(try XCTUnwrap(project.poolDirectory))
        HorizontalPoolLibrary.invalidateCache()
        defer { HorizontalPoolLibrary.invalidateCache() }
        let items = HorizontalPoolLibrary.resolvingInheritance(HorizontalPoolLibrary.items(inPool: poolURL, poolName: "Project pool"))
        let listed = HorizontalPoolBrowserView.listed(items, category: .part, search: "", replacement: replacement)
        XCTAssertEqual(Set(listed.map(\.uuid)), Set([parts.small, parts.smallAlternative, parts.large].map { $0.lowercased() }))
        func item(_ uuid: String) throws -> HorizontalPoolLibraryItem {
            try XCTUnwrap(items.first { $0.category == .part && $0.uuid == uuid.lowercased() })
        }

        // A track on R1's pad stops a package change, and says why, before
        // anything is written.
        try apply([["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 10, "y_mm": 20],
                    "layer": 0, "width_mm": 0.2]])
        archive = try HorizontalProjectArchive.completeProject(from: url)
        project = try HorizontalProject.load(from: url)
        let refusal = try XCTUnwrap(replacement.refusal(for: try item(parts.large), packageName: "R0805", project: project, archive: archive))
        XCTAssertTrue(refusal.hasPrefix("“RC0805-22K” comes in R0805, not R0603, and R1 has tracks on its pads"), refusal)

        // The same package goes through: one edit, both components on the
        // new part, every connection where it was.
        XCTAssertNil(replacement.refusal(for: try item(parts.smallAlternative), packageName: "R0603", project: project, archive: archive))
        let edited = try HorizontalCanvasProjectEdit.archive(
            applying: replacement.operations(partID: parts.smallAlternative), to: archive, in: project, block: replacement.blockID)
        XCTAssertEqual(edited.changes.count, 2)
        XCTAssertEqual(edited.changes.compactMap { $0.bool("cleared_connections") }, [false, false])
        var reloaded = try HorizontalProject.loadSnapshot(of: edited.archive)
        reloaded.rebaseURLs(onto: project)
        let store = HorizontalArchiveFileStore(archive: edited.archive, baseURL: project.baseURL)
        let blockData = try XCTUnwrap(try store.read(project.baseURL.appendingPathComponent(try XCTUnwrap(project.blockFilename))))
        let components = try JSONHelper.loadDictionary(from: blockData).dictionaryMap("components")
        for refdes in ["R1", "R2"] {
            let component = try XCTUnwrap(components.values.first { $0.string("refdes") == refdes })
            XCTAssertEqual(component.string("part")?.lowercased(), parts.smallAlternative.lowercased(), refdes)
            XCTAssertEqual(component.string("entity")?.lowercased(), parts.entity.lowercased(), "\(refdes) keeps its entity")
        }
        let r1 = try XCTUnwrap(components.values.first { $0.string("refdes") == "R1" })
        XCTAssertEqual(r1.dictionary("connections")?.count, 2, "R1's two connections stay")
        XCTAssertEqual(components.values.first { $0.string("refdes") == "R2" }?.dictionary("connections")?.count, 1)
        // The board shows each part where it was, its package's pads drawn.
        let r1ID = try XCTUnwrap(ids["R1"]), r2ID = try XCTUnwrap(ids["R2"])
        func placement(_ id: String, on board: HorizontalBoard?) throws -> HorizontalPlacement {
            try XCTUnwrap(board?.packages.first { $0.componentID?.lowercased() == id })
        }
        func pads(_ id: String, on board: HorizontalBoard?) throws -> Set<String> {
            let prefix = try placement(id, on: board).id + "/pad/"
            return Set((board?.packagePads ?? []).compactMap { pad -> String? in
                guard pad.id.hasPrefix(prefix) else { return nil }
                return pad.id.dropFirst(prefix.count).split(separator: "/").first.map { $0.lowercased() }
            })
        }
        XCTAssertEqual(try pads(r1ID, on: reloaded.board), parts.smallPads)
        XCTAssertEqual(try placement(r1ID, on: reloaded.board).componentDetails?.mpn, "RC0603-22K", "the board shows the new MPN")
        XCTAssertEqual(try placement(r1ID, on: reloaded.board).position, try placement(r1ID, on: project.board).position)

        // Unrouted, R2 takes the part in the other package, and the board
        // draws R2 in that package where it was placed.
        let r2Only = try XCTUnwrap(HorizontalPartReplacement.current(componentIDs: [r2ID], archive: edited.archive, project: reloaded))
        XCTAssertNil(r2Only.refusal(for: try item(parts.large), packageName: "R0805", project: reloaded, archive: edited.archive))
        let resized = try HorizontalCanvasProjectEdit.archive(applying: r2Only.operations(partID: parts.large), to: edited.archive, in: reloaded)
        let board = try HorizontalProject.loadSnapshot(of: resized.archive).board
        XCTAssertEqual(try pads(r2ID, on: board), parts.largePads)
        XCTAssertEqual(try placement(r2ID, on: board).componentDetails?.packageName, "R0805")
        XCTAssertEqual(try placement(r2ID, on: board).position, try placement(r2ID, on: project.board).position)
        XCTAssertEqual(try pads(r1ID, on: board), parts.smallPads, "R1 untouched")
    }
}
