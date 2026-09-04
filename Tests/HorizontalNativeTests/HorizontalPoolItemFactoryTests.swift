import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// New and duplicated pool items: upstream's seeding, file layout and
/// naming rules.
final class HorizontalPoolItemFactoryTests: XCTestCase {
    private var poolURL: URL!

    override func setUpWithError() throws {
        poolURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolItemFactoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: poolURL, withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(["type": "pool", "uuid": "pool-1", "name": "T"])
            .write(to: poolURL.appendingPathComponent("pool.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: poolURL)
    }

    func testSeedingFollowsUpstream() throws {
        let unit = HorizontalPoolUnit(uuid: "u1", name: "Op-amp", manufacturer: "Acme")
        let entity = HorizontalPoolItemFactory.newEntity(for: unit)
        XCTAssertEqual(entity.name, "Op-amp")
        XCTAssertEqual(entity.gates.count, 1)
        XCTAssertEqual(entity.gates.values.first?.name, "Main")
        XCTAssertEqual(entity.gates.values.first?.unitID, "u1")
        XCTAssertTrue(HorizontalPoolItemFactory.newEntity().gates.isEmpty)

        let symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        XCTAssertEqual(symbol.name, "Op-amp")
        XCTAssertEqual(symbol.unitID, "u1")
        XCTAssertNotEqual(symbol.uuid, unit.uuid)

        let part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: "k1")
        XCTAssertEqual(part.attribute(.mpn).value, "Op-amp")
        XCTAssertEqual(part.attribute(.manufacturer).value, "Acme")
        XCTAssertEqual(part.entityID, entity.uuid)
        XCTAssertEqual(part.packageID, "k1")

        var base = part
        base.attributes[.value] = HorizontalPartAttribute(value: "10k")
        let derived = HorizontalPoolItemFactory.newPart(basedOn: base)
        XCTAssertEqual(derived.baseID, base.uuid)
        XCTAssertNil(derived.entityID)
        XCTAssertNil(derived.packageID)
        XCTAssertTrue(derived.attribute(.value).inherited)
        XCTAssertEqual(derived.attribute(.value).value, "10k")
        XCTAssertTrue(derived.inheritTags)
        XCTAssertNoThrow(try HorizontalHorizonJSONWriter.data(derived.json()))
    }

    func testDuplicateRenamesAndReidentifies() throws {
        let unit = HorizontalPoolUnit(uuid: "u1", name: "R")
        guard case .unit(let copy) = HorizontalPoolItemFactory.duplicate(.unit(unit)) else {
            return XCTFail("expected a unit")
        }
        XCTAssertEqual(copy.name, "R (Copy)")
        XCTAssertNotEqual(copy.uuid, "u1")

        let part = HorizontalPoolPartItem(uuid: "p1", entityID: "e", packageID: "k", mpn: "ABC")
        guard case .part(let partCopy) = HorizontalPoolItemFactory.duplicate(.part(part)) else {
            return XCTFail("expected a part")
        }
        XCTAssertEqual(partCopy.attribute(.mpn).value, "ABC (Copy)")
        XCTAssertEqual(partCopy.name, "ABC (Copy)")
    }

    func testSuggestedLocationsAndSlugs() {
        XCTAssertEqual(HorizontalPoolItemFactory.slug("Op-Amp, Dual (SOIC 8)", fallback: "x"), "op-amp-dual-soic-8")
        XCTAssertEqual(HorizontalPoolItemFactory.slug("  ", fallback: "unit"), "unit")
        XCTAssertEqual(HorizontalPoolItemFactory.slug("R0603_v2.1", fallback: "x"), "r0603_v2.1")

        let unit = HorizontalPoolUnit(uuid: "u1", name: "Op amp")
        XCTAssertEqual(
            HorizontalPoolItemFactory.suggestedURL(for: .unit(unit), in: poolURL).path,
            poolURL.appendingPathComponent("units/op-amp.json").path
        )
        let package = HorizontalPoolPackage(uuid: "k1", name: "SOIC-8")
        XCTAssertEqual(
            HorizontalPoolItemFactory.suggestedURL(for: .package(package), in: poolURL).path,
            poolURL.appendingPathComponent("packages/soic-8/package.json").path
        )
        // A symbol made for a unit mirrors the unit's path under symbols/.
        let symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        let unitURL = poolURL.appendingPathComponent("units/analog/opamp.json")
        XCTAssertEqual(
            HorizontalPoolItemFactory.suggestedURL(for: .symbol(symbol), in: poolURL, mirroring: unitURL).path,
            poolURL.appendingPathComponent("symbols/analog/opamp.json").path
        )
        XCTAssertEqual(
            HorizontalPoolItemFactory.suggestedDuplicateURL(of: unitURL).lastPathComponent,
            "opamp-copy.json"
        )
        XCTAssertEqual(
            HorizontalPoolItemFactory.suggestedDuplicateURL(of: poolURL.appendingPathComponent("packages/soic-8/package.json")).path,
            poolURL.appendingPathComponent("packages/soic-8-copy/package.json").path
        )
        XCTAssertEqual(HorizontalPoolItemFactory.availableURL(for: unitURL).path, unitURL.path, "nothing there yet")
    }

    func testLocationRulesMirrorCheckFilename() {
        func problem(_ path: String, _ category: HorizontalPoolItemCategory) -> String? {
            HorizontalPoolItemFactory.locationProblem(for: poolURL.appendingPathComponent(path), category: category, in: poolURL)
        }
        XCTAssertNil(problem("units/x/y.json", .unit))
        XCTAssertNotNil(problem("symbols/y.json", .unit))
        XCTAssertNotNil(problem("units/y.txt", .unit))
        XCTAssertNil(problem("packages/r/package.json", .package))
        XCTAssertNotNil(problem("packages/r/other.json", .package))
        XCTAssertNotNil(problem("packages/r/sub/package.json", .package))
        XCTAssertNil(problem("padstacks/a.json", .padstack))
        XCTAssertNil(problem("packages/r/padstacks/a.json", .padstack))
        XCTAssertNotNil(problem("packages/r/a.json", .padstack))
        XCTAssertNotNil(
            HorizontalPoolItemFactory.locationProblem(for: URL(fileURLWithPath: "/tmp/elsewhere/units/a.json"), category: .unit, in: poolURL)
        )
    }

    func testWriteCreatesDirectoriesAndRefusesToOverwrite() throws {
        let package = HorizontalPoolPackage(uuid: "k1", name: "SOIC-8")
        let url = HorizontalPoolItemFactory.suggestedURL(for: .package(package), in: poolURL)
        let data = try HorizontalPoolItemFactory.write(.package(package), to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("padstacks").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertThrowsError(try HorizontalPoolItemFactory.write(.package(package), to: url))
        XCTAssertNotEqual(HorizontalPoolItemFactory.availableURL(for: url).path, url.path)
        XCTAssertTrue(HorizontalPoolItemFactory.availableURL(for: url).path.hasSuffix("soic-8-2/package.json"))

        let item = HorizontalPoolItemFactory.libraryItem(for: .package(package), at: url, poolURL: poolURL, poolName: "T")
        XCTAssertEqual(item.uuid, "k1")
        XCTAssertEqual(item.category, .package)
        XCTAssertEqual(item.url, url)
    }

    func testDuplicatePackageCopiesTheDirectoryAndRemapsLocalPadstacks() throws {
        // A package with one package-local padstack and a stray model file.
        let packageDirectory = poolURL.appendingPathComponent("packages/r0603", isDirectory: true)
        let padstackDirectory = packageDirectory.appendingPathComponent("padstacks", isDirectory: true)
        try FileManager.default.createDirectory(at: padstackDirectory, withIntermediateDirectories: true)
        let padstack = HorizontalPoolPadstack(uuid: "ps-local", name: "Local pad")
        try HorizontalHorizonJSONWriter.data(padstack.json()).write(to: padstackDirectory.appendingPathComponent("local.json"))
        var package = HorizontalPoolPackage(uuid: "k1", name: "R0603")
        package.pads["pad-1"] = HorizontalPad(id: "pad-1", name: "1", padstackID: "ps-local")
        package.pads["pad-2"] = HorizontalPad(id: "pad-2", name: "2", padstackID: "ps-pool")
        let packageURL = packageDirectory.appendingPathComponent("package.json")
        try HorizontalHorizonJSONWriter.data(package.json()).write(to: packageURL)
        try Data("model".utf8).write(to: packageDirectory.appendingPathComponent("r0603.step"))

        let newDirectory = poolURL.appendingPathComponent("packages/r0603-copy", isDirectory: true)
        let newURL = try HorizontalPoolItemFactory.duplicatePackage(from: packageURL, to: newDirectory, name: "R0603 (Copy)")
        XCTAssertEqual(newURL.path, newDirectory.appendingPathComponent("package.json").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent("r0603.step").path))

        let copy = try HorizontalPoolPackage(json: JSONHelper.loadDictionary(from: newURL))
        XCTAssertEqual(copy.name, "R0603 (Copy)")
        XCTAssertNotEqual(copy.uuid, "k1")
        let copiedPadstack = try HorizontalPoolPadstack(json: JSONHelper.loadDictionary(from: newDirectory.appendingPathComponent("padstacks/local.json")))
        XCTAssertNotEqual(copiedPadstack.uuid, "ps-local")
        XCTAssertEqual(copy.pads["pad-1"]?.padstackID, copiedPadstack.uuid, "the pad follows its local padstack's new uuid")
        XCTAssertEqual(copy.pads["pad-2"]?.padstackID, "ps-pool", "pool padstacks are untouched")

        // The original is untouched.
        let original = try HorizontalPoolPackage(json: JSONHelper.loadDictionary(from: packageURL))
        XCTAssertEqual(original.uuid, "k1")
        XCTAssertEqual(original.pads["pad-1"]?.padstackID, "ps-local")

        XCTAssertThrowsError(try HorizontalPoolItemFactory.duplicatePackage(from: packageURL, to: newDirectory, name: "x"))
    }
}
