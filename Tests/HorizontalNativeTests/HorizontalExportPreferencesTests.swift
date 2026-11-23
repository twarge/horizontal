import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The Export sidebar's choices, which the app remembers: which sections
/// Export All writes and each section's options, the same in the next window
/// and at the next launch. The folder, the file names and the layers are a
/// project's own and are made afresh for each.
final class HorizontalExportPreferencesTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "horizontal-export-preferences-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func project(named name: String) throws -> HorizontalProject {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-export-preferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("\(name).horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        return try HorizontalProject.load(from: url)
    }

    func testABoardDXFIsLeftOutUntilAskedFor() throws {
        let project = try project(named: "First")
        let settings = HorizontalExportSettings(project: project)
        XCTAssertFalse(settings.isEnabled(.boardDXF))
        XCTAssertEqual(HorizontalExportSection.allCases.filter { settings.isEnabled($0) },
                       [.schematicPDF, .bom, .gerber, .odb, .pickAndPlace, .boardSTEP, .boardDrawing], "everything else, as before")
        XCTAssertTrue(HorizontalExportSettings.remembered(for: project, defaults: try makeDefaults()) == settings,
                       "nothing remembered, nothing changed")
    }

    func testTheNextProjectOpensWithTheChoicesMadeInTheLast() throws {
        let defaults = try makeDefaults()
        let first = try project(named: "First")
        var chosen = HorizontalExportSettings.remembered(for: first, defaults: defaults)
        chosen.boardDXF.enabled = true
        chosen.boardDXF.includeHoles = false
        chosen.odb.enabled = false
        chosen.bom.columns = [.mpn, .quantity]
        chosen.bom.sortColumn = .mpn
        chosen.bom.includeNoPopulate = false
        chosen.gerber.zipOutput = false
        chosen.gerber.drillMode = .merged
        chosen.pickAndPlace.mode = .individual
        chosen.pickAndPlace.topSide = "T"
        chosen.boardSTEP.copperLayers = .outer
        chosen.boardSTEP.omitSmallComponents = true
        chosen.boardSTEP.minimumComponentSizeMM = 3.5
        chosen.boardDrawing.mirrored = true
        chosen.schematicPDF.minimumLineWidthMM = 0.05
        // And what is the project's own.
        chosen.targetDirectory = "/somewhere/else"
        chosen.bom.filename = "Mine.csv"
        if !chosen.gerber.layers.isEmpty { chosen.gerber.layers[0].enabled.toggle() }
        HorizontalExportPreferences(chosen).save(to: defaults)

        let second = try project(named: "Second")
        let opened = HorizontalExportSettings.remembered(for: second, defaults: defaults)
        XCTAssertTrue(opened.isEnabled(.boardDXF))
        XCTAssertFalse(opened.boardDXF.includeHoles)
        XCTAssertFalse(opened.isEnabled(.odb))
        XCTAssertTrue(opened.isEnabled(.gerber), "a section left on stays on")
        XCTAssertEqual(opened.bom.columns, [.mpn, .quantity])
        XCTAssertEqual(opened.bom.sortColumn, .mpn)
        XCTAssertFalse(opened.bom.includeNoPopulate)
        XCTAssertFalse(opened.gerber.zipOutput)
        XCTAssertEqual(opened.gerber.drillMode, .merged)
        XCTAssertEqual(opened.pickAndPlace.mode, .individual)
        XCTAssertEqual(opened.pickAndPlace.topSide, "T")
        XCTAssertEqual(opened.boardSTEP.copperLayers, .outer)
        XCTAssertTrue(opened.boardSTEP.omitSmallComponents)
        XCTAssertEqual(opened.boardSTEP.minimumComponentSizeMM, 3.5)
        XCTAssertTrue(opened.boardDrawing.mirrored)
        XCTAssertEqual(opened.schematicPDF.minimumLineWidthMM, 0.05)

        let fresh = HorizontalExportSettings(project: second)
        XCTAssertEqual(opened.targetDirectory, fresh.targetDirectory, "beside its own project")
        XCTAssertEqual(opened.bom.filename, fresh.bom.filename, "named for its own project")
        XCTAssertEqual(opened.gerber.layers, fresh.gerber.layers, "its own board's layers")
        XCTAssertEqual(HorizontalExportPreferences(opened), HorizontalExportPreferences(chosen), "the same choices")
    }

    /// A build that knew fewer choices, or more: what it saved still reads,
    /// and a choice this build doesn't know is passed over.
    func testWhatAnotherBuildRememberedStillReads() throws {
        let defaults = try makeDefaults()
        let saved = #"{"enabledSections":{"boardDXF":true,"hologram":true},"bomColumns":["mpn","no_such_column"],"#
            + #""gerberDrillMode":"sideways","stepMinimumComponentSizeMM":-1,"somethingNew":7}"#
        defaults.set(Data(saved.utf8), forKey: HorizontalExportPreferences.defaultsKey)
        let project = try project(named: "First")
        let fresh = HorizontalExportSettings(project: project)
        let opened = HorizontalExportSettings.remembered(for: project, defaults: defaults)
        XCTAssertTrue(opened.isEnabled(.boardDXF))
        XCTAssertTrue(opened.isEnabled(.bom), "not said, so as the app has it")
        XCTAssertEqual(opened.bom.columns, [.mpn])
        XCTAssertEqual(opened.gerber.drillMode, fresh.gerber.drillMode, "a mode this build doesn't know")
        XCTAssertEqual(opened.boardSTEP.minimumComponentSizeMM, fresh.boardSTEP.minimumComponentSizeMM, "no size at all")
        XCTAssertEqual(opened.pickAndPlace, fresh.pickAndPlace)

        defaults.set(Data("not json".utf8), forKey: HorizontalExportPreferences.defaultsKey)
        XCTAssertEqual(HorizontalExportSettings.remembered(for: project, defaults: defaults), fresh, "unreadable: the app's own defaults")
    }
}
