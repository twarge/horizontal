import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The plane editor's model half: a plane defined on a copper polygon pours
/// copper, its settings reach the board JSON, and the editor's draft keeps
/// the plane's mirrored fields in step.
final class HorizontalPlaneEditorTests: XCTestCase {
    private let mm = 1_000_000.0

    private func writtenTemplate() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-plane-editor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        return packageURL
    }

    private func square(_ id: String, size: Double, layer: Int) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: size, y: 0),
            HorizontalPoint(x: size, y: size), HorizontalPoint(x: 0, y: size),
        ], layer: layer)
    }

    func testADraftMakesAPlaneWhoseLegacyFieldsFollowItsSettings() {
        var settings = HorizontalPlaneSettings.default
        settings.minWidth = Int(0.3 * mm)
        settings.keepOrphans = true
        settings.fillStyle = .hatch
        settings.thermalSettings.connectStyle = .thermal
        let draft = HorizontalPlaneEditorDraft(netID: "gnd", priority: 3, fromRules: false, settings: settings)
        let plane = HorizontalPlane(polygon: square("poly", size: 10 * mm, layer: 0), draft: draft)
        XCTAssertEqual(plane.netID, "gnd")
        XCTAssertEqual(plane.polygonID, "poly")
        XCTAssertEqual(plane.layer, 0)
        XCTAssertEqual(plane.priority, 3)
        XCTAssertFalse(plane.fromRules)
        XCTAssertEqual(plane.settings, settings)
        XCTAssertEqual(plane.fillStyle, "hatch")
        XCTAssertEqual(plane.minWidth, 0.3 * mm)
        XCTAssertTrue(plane.keepOrphans)
        XCTAssertEqual(HorizontalPlaneEditorDraft(plane: plane), draft, "the editor reads the plane back the same")
    }

    func testAPlaneDefinedOnACopperPolygonPoursAndPersists() throws {
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        var board = try XCTUnwrap(project.board)
        board.netDetails["gnd"] = HorizontalNetDetails(id: "gnd", name: "GND")
        board.polygons.append(square("outline", size: 40 * mm, layer: HorizontalBoardLayers.outline))
        let polygon = square("pour", size: 20 * mm, layer: HorizontalBoardLayers.topCopper)
        board.polygons.append(polygon)

        var settings = HorizontalPlaneSettings.default
        settings.minWidth = Int(0.25 * mm)
        settings.thermalSettings.connectStyle = .thermal
        settings.thermalSettings.thermalGapWidth = Int(0.3 * mm)
        settings.thermalSettings.nSpokes = 2
        let draft = HorizontalPlaneEditorDraft(netID: "gnd", priority: 1, fromRules: false, settings: settings)
        board.planes.append(HorizontalPlane(polygon: polygon, draft: draft))

        // Horizon's orphan rule: fill that touches nothing on the net is
        // dropped unless the plane keeps orphans.
        let unconnected = try XCTUnwrap(HorizontalBoardPlaneUpdater.updateAllPlanes(in: board).planes.first)
        XCTAssertTrue(unconnected.fragments.isEmpty, "no GND copper inside: nothing to keep")
        var keptBoard = board
        keptBoard.planes[0].settings.keepOrphans = true
        let kept = try XCTUnwrap(HorizontalBoardPlaneUpdater.updateAllPlanes(in: keptBoard).planes.first)
        XCTAssertFalse(kept.fragments.isEmpty)
        XCTAssertTrue(kept.fragments.allSatisfy(\.orphan))

        // A GND pad inside the polygon anchors the fill.
        board.packagePads.append(HorizontalPolygon(id: "pkg/pad/p1/shape/s1/layer/0", vertices: [
            HorizontalPoint(x: 9 * mm, y: 9 * mm), HorizontalPoint(x: 11 * mm, y: 9 * mm),
            HorizontalPoint(x: 11 * mm, y: 11 * mm), HorizontalPoint(x: 9 * mm, y: 11 * mm),
        ], layer: HorizontalBoardLayers.topCopper, netID: "gnd"))
        let poured = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board)
        let plane = try XCTUnwrap(poured.planes.first)
        XCTAssertFalse(plane.fragments.isEmpty, "the pour fills the polygon")
        XCTAssertTrue(plane.fragments.contains { !$0.orphan }, "the pad's copper anchors the fill")
        let area = plane.fragments.flatMap(\.paths).map { HorizontalBoardOutlines.signedArea($0) }.reduce(0) { $0 + abs($1) }
        XCTAssertGreaterThan(area, 300 * mm * mm, "most of a 20 × 20 mm polygon pours")

        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        try HorizontalProjectJSONApplicator.apply(board: poured, in: project, to: &archive)
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let planes = try XCTUnwrap(json["planes"] as? [String: Any])
        let item = try XCTUnwrap(planes[plane.id] as? [String: Any])
        XCTAssertEqual(item["net"] as? String, "gnd")
        XCTAssertEqual(item["polygon"] as? String, "pour")
        XCTAssertEqual(item["priority"] as? Int, 1)
        XCTAssertEqual(item["from_rules"] as? Bool, false)
        let written = try XCTUnwrap(item["settings"] as? [String: Any])
        XCTAssertEqual(written["min_width"] as? Int, Int(0.25 * mm))
        XCTAssertEqual(written["connect_style"] as? String, "thermal")
        XCTAssertEqual(written["thermal_gap_width"] as? Int, Int(0.3 * mm))
        XCTAssertEqual(written["n_spokes"] as? Int, 2)
        XCTAssertEqual(written["style"] as? String, "round")
    }
}
