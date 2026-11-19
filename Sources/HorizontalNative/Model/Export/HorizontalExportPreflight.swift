import Foundation
import HorizontalProjectIO

/// What the rules checks found in a design as it was exported, counted as the
/// rules results sidebar counts them. The files are written all the same: the
/// export says so beside them, and the sidebar lists what was found.
struct HorizontalExportCheckSummary: Equatable, Sendable {
    /// What Horizon fails.
    var errors = 0
    /// What Horizon warns of.
    var warnings = 0

    var isEmpty: Bool { errors == 0 && warnings == 0 }

    /// "The rules checks found 2 errors and 1 warning."
    var message: String {
        let found = [errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil,
                     warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil].compactMap { $0 }
        return found.isEmpty ? "The rules checks found nothing." : "The rules checks found \(found.joined(separator: " and "))."
    }
}

/// What Export All does round the writing of its files, so that what goes to
/// a fabricator is the board as designed and its faults are not found there:
/// planes that Clear All Planes emptied are poured for it, and the rules
/// checks run on what it wrote.
enum HorizontalExportPreflight {
    /// `project` as an export reads it: with its planes poured where Clear
    /// All Planes had emptied them. Cleared planes are a way of seeing the
    /// board, and stay cleared in the window; the copy here is the export's
    /// alone, and Gerbers made from the window's board would have no pours.
    static func pouringClearedPlanes(in project: HorizontalProject) -> HorizontalProject {
        guard let cleared = project.board, cleared.planeFillsCleared, !cleared.planes.isEmpty else {
            return project
        }
        var board = HorizontalBoardPlaneUpdater.updateAllPlanes(in: cleared)
        // The fills join the copper they reach, so the rats' nest follows
        // them, made as a pour's is: after the connectivity pass.
        var resolved = HorizontalBoardConnectivity.recompute(board)
        resolved.regenerateAirwires()
        board.airwires = resolved.airwires
        var project = project
        project.board = board
        return project
    }

    /// The rules checks on `project`, every one the rules results sidebar
    /// runs: the rules' own validation, the board's checks and the
    /// schematic's Connectivity rule. `archive` is the document's, which the
    /// rules and the blocks are read from; without it only the board's
    /// checks run.
    static func checks(of project: HorizontalProject, archive: HorizontalProjectArchive?) -> HorizontalExportCheckSummary {
        var summary = HorizontalExportCheckSummary()
        func count(isError: Bool) {
            if isError {
                summary.errors += 1
            } else {
                summary.warnings += 1
            }
        }
        if let board = project.board {
            if let archive, let rules = try? HorizontalProjectJSONApplicator.boardRules(in: project, from: archive) {
                let context = HorizontalBoardRuleContext(board: board, netClasses: project.schematic?.netClasses ?? [])
                for message in HorizontalBoardRulesValidator.validateAll(rules: rules, context: context) {
                    count(isError: message.level == .error)
                }
            }
            let results = HorizontalBoardRulesCheck.run(board: board, tiedNets: HorizontalBoardClearanceCheck.tiedNets(of: project))
            for finding in results?.all ?? [] {
                count(isError: finding.level == .error)
            }
        }
        if project.schematic != nil, let archive {
            let rules = HorizontalSchematicRules(json: try? HorizontalProjectJSONApplicator.schematicRules(in: project, from: archive))
            for finding in HorizontalSchematicRulesCheck.findings(project: project, archive: archive, rules: rules) {
                count(isError: finding.isError)
            }
        }
        return summary
    }

    /// Export All, as both the Mac and the iPad run it: `HorizontalExportBackend.export`
    /// of `project` with cleared planes poured, off the main thread, and the
    /// rules checks beside it. What they found is in the status of an export
    /// that wrote its files (`checks`); one that failed says why instead.
    static func export(
        sections: [HorizontalExportSection],
        settings: HorizontalExportSettings,
        project: HorizontalProject,
        archive: HorizontalProjectArchive?,
        schematicPDFPalette: HorizontalCanvasPalette,
        boardPDFPalette: HorizontalCanvasPalette,
        silkscreenClipping: HorizontalSilkscreenClipping?
    ) async -> HorizontalExportStatus {
        let prepared = await Task.detached(priority: .userInitiated) {
            pouringClearedPlanes(in: project)
        }.value
        async let written = Task.detached(priority: .userInitiated) {
            HorizontalExportBackend.export(
                sections: sections,
                settings: settings,
                project: prepared,
                schematicPDFPalette: schematicPDFPalette,
                boardPDFPalette: boardPDFPalette,
                silkscreenClipping: silkscreenClipping
            )
        }.value
        async let found = Task.detached(priority: .userInitiated) {
            checks(of: prepared, archive: archive)
        }.value
        var status = await written
        let summary = await found
        if status.kind == .success, !summary.isEmpty {
            status.checks = summary
        }
        return status
    }
}
