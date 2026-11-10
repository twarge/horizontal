import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Deleting a pool item: each kind's files go (a package's whole folder),
/// the library forgets it without a restart, what uses it is named first,
/// and pools the app mustn't write are refused. The "trash" is a folder in
/// the test's temporary directory, so nothing reaches the user's Trash.
final class HorizontalPoolItemDeletionTests: XCTestCase {
    private var root: URL!
    private var pool: URL!
    private var trash: URL!
    private var trashed = [String]()

    private var unit: HorizontalPoolUnit!
    private var symbol: HorizontalPoolSymbol!
    private var entity: HorizontalPoolEntity!
    private var padstack: HorizontalPoolPadstack!
    private var localPadstack: HorizontalPoolPadstack!
    private var package: HorizontalPoolPackage!
    private var part: HorizontalPoolPartItem!
    private var derived: HorizontalPoolPartItem!
    private var frame: HorizontalPoolFrame!
    private var decal: HorizontalPoolDecal!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolItemDeletionTests-\(UUID().uuidString)", isDirectory: true)
        trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        HorizontalPoolRegistryStore.defaults = try XCTUnwrap(UserDefaults(suiteName: "HorizontalPoolItemDeletionTests-\(UUID().uuidString)"))
        HorizontalPoolLibrary.invalidateCache()

        pool = root.appendingPathComponent("mine", isDirectory: true)
        try HorizontalPoolCreation.create(at: pool, name: "Mine", uuid: "11111111-2222-4333-8444-555555555555")
        pool = HorizontalPoolLibrary.canonicalURL(pool)

        unit = HorizontalPoolItemFactory.newUnit()
        unit.name = "Resistor"
        try save(.unit(unit))
        symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        try save(.symbol(symbol))
        entity = HorizontalPoolItemFactory.newEntity(for: unit)
        try save(.entity(entity))
        padstack = HorizontalPoolItemFactory.newPadstack()
        padstack.name = "SMD rect"
        try save(.padstack(padstack))
        package = HorizontalPoolItemFactory.newPackage()
        package.name = "R0402"
        let packageURL = try save(.package(package))
        localPadstack = HorizontalPoolItemFactory.newPadstack()
        localPadstack.name = "Local pad"
        try save(.padstack(localPadstack), at: packageURL.deletingLastPathComponent().appendingPathComponent("padstacks/local.json"))
        // Pads on the pool's padstack and on the package's own, and a 3D
        // model in the pool's shared 3d_models folder.
        var packageJSON = try JSONHelper.loadDictionary(from: packageURL)
        packageJSON["pads"] = [
            "a0000000-0000-4000-8000-000000000001": ["padstack": padstack.uuid, "name": "1"],
            "a0000000-0000-4000-8000-000000000002": ["padstack": localPadstack.uuid, "name": "2"],
        ]
        packageJSON["models"] = ["b0000000-0000-4000-8000-000000000001": ["filename": "3d_models/r0402.step"]]
        try HorizontalHorizonJSONWriter.data(packageJSON).write(to: packageURL)
        try Data("step".utf8).write(to: pool.appendingPathComponent("3d_models/r0402.step"))

        part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        part.attributes[.mpn] = HorizontalPartAttribute(inherited: false, value: "RC0402")
        try save(.part(part))
        derived = HorizontalPoolItemFactory.newPart(basedOn: part)
        derived.attributes[.mpn] = HorizontalPartAttribute(inherited: false, value: "RC0402-1K")
        try save(.part(derived), at: pool.appendingPathComponent("parts/derived.json"))
        frame = HorizontalPoolItemFactory.newFrame()
        frame.name = "A4"
        try save(.frame(frame))
        decal = HorizontalPoolItemFactory.newDecal()
        decal.name = "Logo"
        try save(.decal(decal))
        HorizontalPoolLibrary.invalidateCache()
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        if let pool {
            chmod(pool.appendingPathComponent("frames").path, 0o755)
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func save(_ model: HorizontalPoolItemModel, at url: URL? = nil) throws -> URL {
        let url = url ?? HorizontalPoolItemFactory.suggestedURL(for: model, in: pool)
        XCTAssertNil(HorizontalPoolItemFactory.locationProblem(for: url, category: model.category, in: pool))
        try HorizontalPoolItemFactory.write(model, to: url)
        return url
    }

    private func items(in poolURL: URL? = nil) -> [HorizontalPoolLibraryItem] {
        let poolURL = poolURL ?? pool!
        return HorizontalPoolLibrary.items(inPool: poolURL, poolName: HorizontalPoolRegistryStore.poolInfo(at: poolURL).name)
    }

    private var index: HorizontalPoolLibraryIndex {
        HorizontalPoolLibraryIndex(items: HorizontalPoolLibrary.resolvingInheritance(items()))
    }

    private func item(_ category: HorizontalPoolItemCategory, _ uuid: String) throws -> HorizontalPoolLibraryItem {
        try XCTUnwrap(items().first { $0.category == category && $0.uuid == uuid.lowercased() }, "\(category) \(uuid)")
    }

    /// Moves into the test's own trash folder, as the Trash would.
    private func remover(_ url: URL) throws -> Bool {
        let destination = trash.appendingPathComponent("\(trashed.count)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        trashed.append(HorizontalPoolItemFactory.relativePath(of: url, within: pool) ?? url.path)
        return true
    }

    private func delete(_ category: HorizontalPoolItemCategory, _ uuid: String) throws -> HorizontalPoolItemDeletion {
        let deletion = try HorizontalPoolItemDeletion.plan(for: item(category, uuid), index: index)
        XCTAssertFalse(deletion.isInUse, "\(category) is used by \(deletion.users.map(\.name))")
        try deletion.perform(remove: remover)
        XCTAssertFalse(items().contains { $0.category == category && $0.uuid == uuid.lowercased() }, "\(category) still listed")
        return deletion
    }

    func testDeletingEachKindOfItemTakesItsFilesAndTheLibraryForgetsIt() throws {
        XCTAssertEqual(items().count, 10)
        try delete(.part, derived.uuid)
        try delete(.part, part.uuid)
        try delete(.symbol, symbol.uuid)
        try delete(.entity, entity.uuid)
        try delete(.unit, unit.uuid)
        let packageDeletion = try delete(.package, package.uuid)
        try delete(.padstack, padstack.uuid)
        try delete(.frame, frame.uuid)
        try delete(.decal, decal.uuid)

        // The package went as its folder, its own padstack with it; the
        // shared 3D model stays, as Horizon leaves it.
        XCTAssertEqual(trashed, [
            "parts/derived.json", "parts/rc0402.json", "symbols/resistor.json", "entities/resistor.json",
            "units/resistor.json", "packages/r0402", "padstacks/smd-rect.json", "frames/a4.json", "decals/logo.json",
        ])
        XCTAssertEqual(packageDeletion.keptModels, ["3d_models/r0402.step"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pool.appendingPathComponent("3d_models/r0402.step").path))
        XCTAssertEqual(items(), [])
        // The pool itself is as Horizon made it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: pool.appendingPathComponent("packages/.keep").path))
    }

    func testDeletingAnItemSomethingUsesNamesTheUsersAndDeletesOnlyWhenAskedToBreakThem() throws {
        let unitDeletion = try HorizontalPoolItemDeletion.plan(for: item(.unit, unit.uuid), index: index)
        XCTAssertEqual(unitDeletion.users.map(\.category), [.entity, .symbol])
        XCTAssertEqual(unitDeletion.usersDescription,
                       "“Resistor” is used by entity “Resistor” (Mine) and symbol “Resistor” (Mine).")
        XCTAssertThrowsError(try unitDeletion.perform(remove: remover)) { error in
            XCTAssertEqual(error as? HorizontalPoolItemDeletion.Refusal, .inUse(unitDeletion.usersDescription))
        }
        XCTAssertEqual(trashed, [])
        XCTAssertNoThrow(try item(.unit, unit.uuid))

        XCTAssertEqual(try HorizontalPoolItemDeletion.plan(for: item(.entity, entity.uuid), index: index).users.map(\.uuid),
                       [part.uuid, derived.uuid])
        XCTAssertEqual(try HorizontalPoolItemDeletion.plan(for: item(.part, part.uuid), index: index).users.map(\.uuid), [derived.uuid])
        XCTAssertEqual(try HorizontalPoolItemDeletion.plan(for: item(.package, package.uuid), index: index).users.map(\.uuid).sorted(),
                       [part.uuid, derived.uuid].sorted())
        XCTAssertEqual(try HorizontalPoolItemDeletion.plan(for: item(.padstack, padstack.uuid), index: index).users.map(\.uuid), [package.uuid])
        XCTAssertEqual(try HorizontalPoolItemDeletion.plan(for: item(.padstack, localPadstack.uuid), index: index).users.map(\.uuid), [package.uuid])
        XCTAssertFalse(try HorizontalPoolItemDeletion.plan(for: item(.part, derived.uuid), index: index).isInUse)

        try unitDeletion.perform(breakingUsers: true, remove: remover)
        XCTAssertEqual(trashed, ["units/resistor.json"])
        XCTAssertFalse(items().contains { $0.uuid == unit.uuid })
    }

    func testAPartInAPoolIncludingThisOneCountsAsAUser() throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try HorizontalPoolCreation.create(at: other, name: "Other", includedPools: ["11111111-2222-4333-8444-555555555555"])
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: other))
        var theirs = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        theirs.attributes[.mpn] = HorizontalPartAttribute(inherited: false, value: "THEIRS")
        let model = HorizontalPoolItemModel.part(theirs)
        try HorizontalPoolItemFactory.write(model, to: HorizontalPoolItemFactory.suggestedURL(for: model, in: other))
        HorizontalPoolLibrary.invalidateCache()

        // The browsed index is this pool's alone.
        let users = try HorizontalPoolItemDeletion.plan(for: item(.package, package.uuid), index: index).users
        XCTAssertTrue(users.contains { $0.uuid == theirs.uuid && $0.poolName == "Other" }, "\(users.map(\.name))")
    }

    func testThePoolsDefaultViaCountsAsAUse() throws {
        var poolJSON = try JSONHelper.loadDictionary(from: pool.appendingPathComponent("pool.json"))
        poolJSON["default_via"] = padstack.uuid
        try HorizontalHorizonJSONWriter.data(poolJSON).write(to: pool.appendingPathComponent("pool.json"))
        let deletion = try HorizontalPoolItemDeletion.plan(for: item(.padstack, padstack.uuid), index: index)
        XCTAssertEqual(deletion.poolSettings, ["the pool’s default via"])
        XCTAssertTrue(deletion.usersDescription.hasSuffix("package “R0402” (Mine) and the pool’s default via."), deletion.usersDescription)
    }

    func testReadOnlyPoolsProjectPoolsAndBundledItemsAreRefused() throws {
        let decalItem = try item(.decal, decal.uuid)
        XCTAssertThrowsError(try HorizontalPoolItemDeletion.plan(for: decalItem, index: index, readOnlyOperation: true)) { error in
            XCTAssertEqual(error as? HorizontalPoolItemDeletion.Refusal, .readOnlyOperation)
        }

        // A folder the app can't write.
        let frameItem = try item(.frame, frame.uuid)
        XCTAssertEqual(chmod(pool.appendingPathComponent("frames").path, 0o555), 0)
        XCTAssertEqual(HorizontalPoolItemDeletion.refusal(for: frameItem), .notWritable("frames"))
        XCTAssertEqual(chmod(pool.appendingPathComponent("frames").path, 0o755), 0)
        XCTAssertNil(HorizontalPoolItemDeletion.refusal(for: frameItem))

        // A project pool's copy belongs to the project.
        var poolJSON = try JSONHelper.loadDictionary(from: pool.appendingPathComponent("pool.json"))
        poolJSON["uuid"] = HorizontalProjectArchive.projectPoolUUID
        try HorizontalHorizonJSONWriter.data(poolJSON).write(to: pool.appendingPathComponent("pool.json"))
        XCTAssertEqual(HorizontalPoolItemDeletion.refusal(for: decalItem), .projectPool)

        // What ships inside the app's bundle.
        var bundled = decalItem
        bundled.poolURL = Bundle.main.bundleURL.appendingPathComponent("horizon-pool")
        bundled.url = bundled.poolURL.appendingPathComponent("decals/logo.json")
        XCTAssertEqual(HorizontalPoolItemDeletion.refusal(for: bundled), .bundled)

        // A file outside the pool it is listed under.
        var stray = try item(.unit, unit.uuid)
        stray.poolURL = root.appendingPathComponent("other")
        XCTAssertEqual(HorizontalPoolItemDeletion.refusal(for: stray), .notInPool)
        XCTAssertEqual(trashed, [])
    }
}
