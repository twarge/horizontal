import Foundation
import XCTest
@testable import HorizontalNative

/// Meander tuning's geometry and its sizing, as docs/length-tuning.md
/// specifies them: a cell adds 2A − 4k, its corners are chamfers or arcs, the
/// pattern is whole nanometres on an axis or a diagonal, and a target is met
/// to a step or the shortfall said.
final class HorizontalMeanderTests: XCTestCase {
    private let mm = 1_000_000.0

    private func lattice(_ from: (Double, Double), _ to: (Double, Double)) throws -> HorizontalMeander.Lattice {
        try XCTUnwrap(HorizontalMeander.lattice(from: HorizontalPoint(x: from.0 * mm, y: from.1 * mm),
                                                to: HorizontalPoint(x: to.0 * mm, y: to.1 * mm)))
    }

    private func isWhole(_ point: HorizontalPoint) -> Bool {
        point.x == point.x.rounded() && point.y == point.y.rounded()
    }

    /// One of the eight routing directions.
    private func isOctilinear(_ piece: HorizontalMeander.Piece) -> Bool {
        let dx = piece.to.x - piece.from.x, dy = piece.to.y - piece.from.y
        return dx == 0 || dy == 0 || abs(dx) == abs(dy)
    }

    func testTheLatticeIsTheBaselinesStepsAlongAndAcross() throws {
        let axis = try lattice((1, 2), (11, 2))
        XCTAssertEqual(axis.steps, 10_000_000)
        XCTAssertEqual(axis.unit, 1)
        XCTAssertEqual(axis.point(3, 4), HorizontalPoint(x: 1 * mm + 3, y: 2 * mm + 4), "left of east is north")
        let diagonal = try lattice((0, 0), (-3, 3))
        XCTAssertEqual(diagonal.unit, 2.squareRoot())
        XCTAssertEqual(diagonal.steps, 3_000_000)
        let point = diagonal.point(5, 7)
        XCTAssertTrue(isWhole(point))
        let back = diagonal.coordinates(of: point)
        XCTAssertEqual(back.u, 5, accuracy: 1e-9)
        XCTAssertEqual(back.v, 7, accuracy: 1e-9)
        XCTAssertNil(HorizontalMeander.lattice(from: .zero, to: HorizontalPoint(x: 3, y: 1)), "no routing direction")
        XCTAssertNil(HorizontalMeander.lattice(from: .zero, to: HorizontalPoint(x: 0.5, y: 0)), "not whole")
        XCTAssertNil(HorizontalMeander.lattice(from: .zero, to: .zero))
    }

    func testACellAddsTwoAmplitudesLessItsCorners() throws {
        for corner in HorizontalMeander.Corner.allCases {
            for base in [try lattice((0, 0), (20, 0)), try lattice((0, 0), (14, 14)), try lattice((5, 5), (5, -15))] {
                let cell = HorizontalMeander.Cell(start: base.steps / 3, spacing: 400_000, side: 1,
                                                  amplitude: 900_000, corner: corner == .arc ? 200_000 : 100_000)
                let pieces = HorizontalMeander.pieces(lattice: base, cells: [cell], corner: corner)
                let baseline = Double(base.steps) * base.unit
                let expected = baseline + HorizontalMeander.addedLength(
                    amplitude: cell.amplitude, corner: cell.corner, style: corner, unit: base.unit)
                XCTAssertEqual(HorizontalMeander.length(of: pieces), expected, accuracy: 1e-3, "\(corner) on \(base)")
                XCTAssertEqual(pieces.first?.from, base.point(0, 0))
                XCTAssertEqual(pieces.last?.to, base.point(base.steps, 0))
                for (piece, next) in zip(pieces, pieces.dropFirst()) {
                    XCTAssertEqual(piece.to, next.from, "the pieces chain")
                }
                for piece in pieces {
                    XCTAssertTrue(isWhole(piece.from) && isWhole(piece.to), "whole nanometres")
                    if let center = piece.center {
                        XCTAssertTrue(isWhole(center))
                        let r0 = hypot(piece.from.x - center.x, piece.from.y - center.y)
                        let r1 = hypot(piece.to.x - center.x, piece.to.y - center.y)
                        XCTAssertEqual(r0, r1, accuracy: 1e-6, "on one circle")
                    } else {
                        XCTAssertTrue(isOctilinear(piece), "a chamfer runs at 45°: \(piece)")
                    }
                }
                XCTAssertEqual(pieces.filter { $0.center != nil }.count, corner == .arc ? 4 : 0)
            }
        }
        // The losses are the geometry's: (2 − √2) a chamfer, (2 − π/2) an arc.
        XCTAssertEqual(HorizontalMeander.Corner.chamfer.loss, 0.5857864, accuracy: 1e-6)
        XCTAssertEqual(HorizontalMeander.Corner.arc.loss, 0.4292037, accuracy: 1e-6)
    }

    func testCellsOnAlternateSidesMakeASerpentine() throws {
        let base = try lattice((0, 0), (20, 0))
        let cells = [0, 1, 2].map {
            HorizontalMeander.Cell(start: 2_000_000 + $0 * 1_200_000, spacing: 600_000, side: $0 % 2 == 0 ? 1 : -1,
                                   amplitude: 800_000, corner: 150_000)
        }
        let pieces = HorizontalMeander.pieces(lattice: base, cells: cells, corner: .chamfer)
        let ys = pieces.flatMap { [$0.from.y, $0.to.y] }
        XCTAssertEqual(ys.max(), 800_000)
        XCTAssertEqual(ys.min(), -800_000)
        XCTAssertEqual(HorizontalMeander.length(of: pieces),
                       20 * mm + 3 * HorizontalMeander.addedLength(amplitude: 800_000, corner: 150_000, style: .chamfer, unit: 1),
                       accuracy: 1e-3)
    }

    func testSlotsGoFromTheAnchorTowardsTheCursorKeepingTheMargins() throws {
        let base = try lattice((0, 0), (20, 0))
        let forward = HorizontalMeander.slots(lattice: base, anchor: 1_000_000, toward: 10_000_000,
                                              spacing: 600_000, corner: 150_000, margin: 750_000)
        XCTAssertEqual(forward.first, 1_150_000)
        XCTAssertEqual(Array(forward.prefix(3)), [1_150_000, 2_350_000, 3_550_000], "two spacings apart")
        XCTAssertLessThanOrEqual(forward.last! + 600_000 + 150_000, 10_000_000)
        let backward = HorizontalMeander.slots(lattice: base, anchor: 19_900_000, toward: 15_000_000,
                                               spacing: 600_000, corner: 150_000, margin: 750_000)
        XCTAssertEqual(backward.first, 20_000_000 - 750_000 - 150_000 - 600_000, "the far margin, then back")
        XCTAssertGreaterThanOrEqual(backward.last! - 150_000, 15_000_000)
        XCTAssertTrue(HorizontalMeander.slots(lattice: base, anchor: 5_000_000, toward: 5_500_000,
                                              spacing: 600_000, corner: 150_000, margin: 750_000).isEmpty)
    }

    func testAPlanMeetsTheTargetToAStep() throws {
        let base = try lattice((0, 0), (40, 0))
        var settings = HorizontalMeander.Settings()
        let slots = HorizontalMeander.slots(lattice: base, anchor: 0, toward: base.steps,
                                            spacing: 600_000, corner: 150_000, margin: 750_000)
        for corner in HorizontalMeander.Corner.allCases {
            settings.corner = corner
            // From 0.3 mm: a cell no shorter than the track's 0.2 mm width
            // adds about a quarter of a millimetre at least.
            for needed in stride(from: 0.3, through: 12, by: 0.37).map({ $0 * mm }) {
                let plan = HorizontalMeander.plan(needed: needed, lattice: base, slots: slots, settings: settings, side: 1,
                                                  minimumAmplitude: 200_000) { _, _ in .max }
                XCTAssertLessThanOrEqual(abs(plan.residual), 1, "\(corner) \(needed): \(plan.residual)")
                let pieces = HorizontalMeander.pieces(lattice: base, cells: plan.cells, corner: corner)
                XCTAssertEqual(HorizontalMeander.length(of: pieces) - 40 * mm, plan.added, accuracy: 1e-3, "measured as planned")
                for cell in plan.cells {
                    XCTAssertLessThanOrEqual(cell.amplitude, 1_000_000)
                    XCTAssertGreaterThanOrEqual(cell.amplitude, max(200_000, 2 * cell.corner))
                }
                for (cell, next) in zip(plan.cells, plan.cells.dropFirst()) {
                    XCTAssertLessThanOrEqual(cell.span.upperBound, next.span.lowerBound, "cells don't overlap")
                }
                // The same request, the same cells.
                XCTAssertEqual(HorizontalMeander.plan(needed: needed, lattice: base, slots: slots, settings: settings, side: 1,
                                                      minimumAmplitude: 200_000) { _, _ in .max }, plan)
            }
        }
    }

    func testAPlanTakesTheRoomItIsGivenAndSaysWhatIsMissing() throws {
        let base = try lattice((0, 0), (20, 0))
        let settings = HorizontalMeander.Settings()
        let slots = HorizontalMeander.slots(lattice: base, anchor: 0, toward: base.steps,
                                            spacing: 600_000, corner: 150_000, margin: 750_000)
        // The left is blocked at the second slot; a one-sided tune goes right there.
        let plan = HorizontalMeander.plan(needed: 4 * mm, lattice: base, slots: slots, settings: settings, side: 1,
                                          minimumAmplitude: 200_000) { start, side in
            start == slots[1] && side == 1 ? 0 : (start == slots[0] ? 500_000 : .max)
        }
        XCTAssertLessThanOrEqual(abs(plan.residual), 1)
        XCTAssertEqual(plan.cells.first { $0.start == slots[1] }?.side, -1)
        XCTAssertLessThanOrEqual(plan.cells.first { $0.start == slots[0] }?.amplitude ?? 0, 500_000)

        // A serpentine keeps its alternation and drops the slot instead.
        var serpentine = settings
        serpentine.style = .serpentine
        let alternating = HorizontalMeander.plan(needed: 4 * mm, lattice: base, slots: slots, settings: serpentine, side: 1,
                                                 minimumAmplitude: 200_000) { start, side in start == slots[0] && side == 1 ? 0 : .max }
        XCTAssertNil(alternating.cells.first { $0.start == slots[0] })
        XCTAssertEqual(alternating.blocked, 1)
        XCTAssertEqual(alternating.cells.first?.side, -1, "the second slot is the right's")

        // Too little room: as much as fits, and what is missing.
        let short = HorizontalMeander.plan(needed: 50 * mm, lattice: base, slots: slots, settings: settings, side: 1,
                                           minimumAmplitude: 200_000) { _, _ in .max }
        XCTAssertEqual(short.cells.count, slots.count)
        XCTAssertEqual(short.residual, 50 * mm - short.added, accuracy: 1e-6)
        XCTAssertGreaterThan(short.residual, 1 * mm)

        // No room at all.
        let none = HorizontalMeander.plan(needed: 1 * mm, lattice: base, slots: slots, settings: settings, side: 1,
                                          minimumAmplitude: 200_000) { _, _ in 0 }
        XCTAssertTrue(none.cells.isEmpty)
        XCTAssertEqual(none.residual, 1 * mm)
        XCTAssertEqual(none.blocked, slots.count)
    }

    func testATargetTooShortForOneCellTakesSmallerCorners() throws {
        let base = try lattice((0, 0), (20, 0))
        let settings = HorizontalMeander.Settings()
        let slots = HorizontalMeander.slots(lattice: base, anchor: 0, toward: base.steps,
                                            spacing: 600_000, corner: 150_000, margin: 750_000)
        // 0.2 mm: a cell with the settings' 0.15 mm chamfers is 0.3 mm tall
        // at least, two chamfers' worth, and adds 0.25 mm, so it takes
        // smaller ones.
        let plan = HorizontalMeander.plan(needed: 0.2 * mm, lattice: base, slots: slots, settings: settings, side: 1,
                                          minimumAmplitude: 100_000) { _, _ in .max }
        XCTAssertLessThanOrEqual(abs(plan.residual), 1)
        XCTAssertEqual(plan.cells.count, 1)
        XCTAssertLessThan(try XCTUnwrap(plan.cells.first).corner, 150_000)

        // Below what any cell as tall as the track is wide can add, nothing,
        // and it says so.
        let tiny = HorizontalMeander.plan(needed: 0.1 * mm, lattice: base, slots: slots, settings: settings, side: 1,
                                          minimumAmplitude: 200_000) { _, _ in .max }
        XCTAssertTrue(tiny.cells.isEmpty)
        XCTAssertEqual(tiny.residual, 0.1 * mm)
    }
}
