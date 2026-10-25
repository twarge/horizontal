import Foundation
import HorizontalProjectIO
import XCTest

/// The Horizon pool items Horizontal ships: horizon-pool's two via padstacks,
/// as its own files under its own uuids, with its licence and attribution.
final class HorizontalBuiltInPoolTests: XCTestCase {
    private let horizonPool = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Repositories/horizon-pool")

    func testBothViasShipUnderTheirOwnUUIDsAndNames() throws {
        let expected = [
            HorizontalProjectArchive.horizonPoolTentedCircularVia: "Circular via (tented)",
            HorizontalProjectArchive.horizonPoolCircularVia: "Circular via"
        ]
        XCTAssertEqual(Set(HorizontalBuiltInPool.padstackPaths.keys), Set(expected.keys))
        for (uuid, name) in expected {
            let data = try XCTUnwrap(HorizontalBuiltInPool.padstackData(uuid), "\(name) ships")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["uuid"] as? String, uuid)
            XCTAssertEqual(json["name"] as? String, name)
            XCTAssertEqual(json["type"] as? String, "padstack")
            XCTAssertEqual(json["padstack_type"] as? String, "via")
            XCTAssertEqual(HorizontalBuiltInPool.padstackData(uuid.uppercased()), data, "by uuid, whatever its case")
        }
        XCTAssertNil(HorizontalBuiltInPool.padstackData("1c4d3f0a-8e7b-4a6e-9c3d-2b1a0f9e8d7c"), "nothing else ships")
    }

    /// Byte for byte the files horizon-pool has, where a checkout is at hand
    /// to compare with, so a board that names one names horizon-pool's item.
    func testTheShippedFilesAreHorizonPoolsOwn() throws {
        guard FileManager.default.fileExists(atPath: horizonPool.appendingPathComponent("pool.json").path) else {
            throw XCTSkip("no horizon-pool checkout at \(horizonPool.path)")
        }
        for (uuid, path) in HorizontalBuiltInPool.padstackPaths {
            XCTAssertEqual(HorizontalBuiltInPool.padstackData(uuid), try Data(contentsOf: horizonPool.appendingPathComponent(path)), path)
        }
        let pool = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: horizonPool.appendingPathComponent("pool.json"))) as? [String: Any])
        XCTAssertEqual(pool["uuid"] as? String, HorizontalBuiltInPool.horizonPoolUUID)
        XCTAssertEqual(pool["default_via"] as? String, HorizontalProjectArchive.horizonPoolCircularVia)
    }

    /// They are under horizon-pool's licence, which ships beside them with
    /// their attribution.
    func testTheLicenceAndAttributionShipWithThem() throws {
        let tented = try XCTUnwrap(HorizontalBuiltInPool.padstackURL(HorizontalProjectArchive.horizonPoolTentedCircularVia))
        let directory = tented.deletingLastPathComponent().deletingLastPathComponent()
        let licence = try String(contentsOf: directory.appendingPathComponent("LICENSE.md"), encoding: .utf8)
        XCTAssertTrue(licence.contains("CC-BY-SA 4.0"))
        let readme = try String(contentsOf: directory.appendingPathComponent("README.md"), encoding: .utf8)
        for credit in ["Lukas K.", "fruchti", "https://github.com/horizon-eda/horizon-pool", "CC BY-SA 4.0"] {
            XCTAssertTrue(readme.contains(credit), credit)
        }
        if FileManager.default.fileExists(atPath: horizonPool.appendingPathComponent("LICENSE.md").path) {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("LICENSE.md")),
                           try Data(contentsOf: horizonPool.appendingPathComponent("LICENSE.md")))
        }
    }

    /// Where no pool names a default via, a board's default via rule takes
    /// the tented one Horizontal ships; horizon-pool's own default opens the
    /// mask, so its tented sibling stands in for it too.
    func testTheDefaultViaIsTheShippedTentedViaWhereNoPoolNamesOne() {
        let tented = HorizontalProjectArchive.horizonPoolTentedCircularVia
        XCTAssertEqual(HorizontalProjectArchive.defaultViaPadstack(poolDefaultVia: nil), tented)
        XCTAssertEqual(HorizontalProjectArchive.defaultViaPadstack(poolDefaultVia: ""), tented)
        XCTAssertEqual(HorizontalProjectArchive.defaultViaPadstack(poolDefaultVia: HorizontalProjectArchive.nullUUID), tented)
        XCTAssertEqual(HorizontalProjectArchive.defaultViaPadstack(poolDefaultVia: HorizontalProjectArchive.horizonPoolCircularVia.uppercased()), tented)
        XCTAssertEqual(HorizontalProjectArchive.defaultViaPadstack(poolDefaultVia: "1C4D3F0A-8E7B-4A6E-9C3D-2B1A0F9E8D7C"), "1c4d3f0a-8e7b-4a6e-9c3d-2b1a0f9e8d7c")
        XCTAssertEqual(HorizontalProjectArchive.cachedPadstackPath(tented.uppercased()), "padstacks/cache/\(tented).json")
    }
}
