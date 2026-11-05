import Foundation
import XCTest
@testable import HorizontalNative

/// The lengths Horizon's board reads off its tracks — the HUD's total
/// length and spacing, a net's routed length, its skew against its diff pair
/// partner — and the Length Tuning window's list made from them.
final class HorizontalLengthTuningTests: XCTestCase {
    private let mm = 1_000_000.0
    private let tx = "11111111-1111-4111-8111-111111111111"
    private let txn = "22222222-2222-4222-8222-222222222222"

    private func track(_ id: String, _ from: (Double, Double), _ to: (Double, Double), net: String?,
                       width: Double = 200_000, layer: Int = 0, center: (Double, Double)? = nil) -> HorizontalSegment {
        HorizontalSegment(
            id: id,
            from: HorizontalPoint(x: from.0 * mm, y: from.1 * mm),
            to: HorizontalPoint(x: to.0 * mm, y: to.1 * mm),
            width: width,
            layer: layer,
            center: center.map { HorizontalPoint(x: $0.0 * mm, y: $0.1 * mm) },
            netID: net
        )
    }

    private var details: [String: HorizontalNetDetails] {
        [tx: HorizontalNetDetails(id: tx, name: "TX+", diffpairID: txn, isDiffpairPrimary: true),
         txn: HorizontalNetDetails(id: txn, name: "TX-", diffpairID: tx)]
    }

    // MARK: - Lengths

    func testAnArcIsMeasuredAlongItsCircle() {
        let straight = track("a", (0, 0), (3, 4), net: nil)
        XCTAssertEqual(HorizontalTrackLength.length(of: straight), 5 * mm, accuracy: 1e-6)

        // A quarter circle of radius 2 mm, anticlockwise from (2, 0) to (0, 2).
        let quarter = track("b", (2, 0), (0, 2), net: nil, center: (0, 0))
        XCTAssertEqual(HorizontalTrackLength.length(of: quarter), .pi * mm, accuracy: 1e-3)
        // The drawing's polyline falls short of it, which is why tuning
        // doesn't measure that.
        XCTAssertLessThan(quarter.length, HorizontalTrackLength.length(of: quarter) - 50)

        var reversed = quarter
        reversed.reverse = true
        XCTAssertEqual(HorizontalTrackLength.length(of: reversed), 3 * .pi * mm, accuracy: 1e-3)
    }

    func testSpacingIsBetweenTheCentrelinesOfParallelTracks() throws {
        let first = track("a", (0, 0), (10, 0), net: tx)
        let second = track("b", (2, 0.3), (8, 0.3), net: txn, width: 100_000)
        XCTAssertEqual(try XCTUnwrap(HorizontalTrackLength.spacing(first, second)), 0.3 * mm, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(HorizontalTrackLength.spacing(second, first)), 0.3 * mm, accuracy: 1e-6, "a magnitude")
        let diagonal = track("c", (0, 0), (5, 5), net: tx)
        let diagonalNeighbour = track("d", (1, 0), (6, 5), net: txn)
        XCTAssertEqual(try XCTUnwrap(HorizontalTrackLength.spacing(diagonal, diagonalNeighbour)), mm / 2.squareRoot(), accuracy: 1e-3)
        XCTAssertNil(HorizontalTrackLength.spacing(first, diagonal), "not parallel")
        XCTAssertNil(HorizontalTrackLength.spacing(first, track("e", (0, 1), (0, 1), net: nil)), "no direction")
        XCTAssertNil(HorizontalTrackLength.spacing(first, track("f", (2, 0), (0, 2), net: nil, center: (0, 0))), "an arc")
    }

    func testTheSelectionSummaryIsHorizonsTrackHUD() throws {
        let board = [
            track("a", (0, 0), (10, 0), net: tx),
            track("b", (10, 0), (12, 2), net: tx),
            track("c", (0, 0.3), (10, 0.3), net: txn, width: 100_000),
            track("d", (20, 0), (20, 4), net: nil, layer: 31),
        ]
        let pair = try XCTUnwrap(HorizontalTrackSelectionSummary(selected: [board[0], board[2]], board: board, netDetails: details))
        XCTAssertEqual(pair.count, 2)
        XCTAssertEqual(pair.totalLength, 20 * mm, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(pair.spacing), 0.3 * mm, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(pair.gap), 0.15 * mm, accuracy: 1e-6, "less half of each width")
        XCTAssertNil(pair.netRoutedLength, "two nets")
        let pairRows = pair.details(layerName: { "L\($0)" }, netName: { $0 })
        XCTAssertEqual(pairRows.map(\.label), ["Layers", "Total length", "Spacing", "Gap", "Nets"])
        XCTAssertEqual(pairRows.first { $0.label == "Spacing" }?.value, "0.300 mm")

        let one = try XCTUnwrap(HorizontalTrackSelectionSummary(selected: [board[0]], board: board, netDetails: details))
        XCTAssertEqual(try XCTUnwrap(one.netRoutedLength), (10 + 2 * 2.squareRoot()) * mm, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(one.partnerRoutedLength), 10 * mm, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(one.pairSkew), 2 * 2.squareRoot() * mm, accuracy: 1e-3)
        let oneRows = one.details(layerName: { "L\($0)" }, netName: { $0 == txn ? "TX-" : $0 })
        XCTAssertEqual(oneRows.map(\.label), ["Net length", "Pair skew"], "the track's own rows say its length and layer")
        XCTAssertEqual(oneRows.last?.value, "+2.828 mm vs TX-")

        XCTAssertNil(HorizontalTrackSelectionSummary(selected: [], board: board, netDetails: details))
        let netless = try XCTUnwrap(HorizontalTrackSelectionSummary(selected: [board[3]], board: board, netDetails: details))
        XCTAssertNil(netless.netRoutedLength)
        XCTAssertEqual(HorizontalTrackSelectionSummary.measuresAllTracks(HorizontalTrackSelectionSummary.measureAllActionID), true)
        XCTAssertEqual(HorizontalTrackSelectionSummary.measuresAllTracks(HorizontalTrackSelectionSummary.measureActionID), false)
        XCTAssertNil(HorizontalTrackSelectionSummary.measuresAllTracks("width"))
    }

    func testLengthsAreWrittenToTheMicrometre() {
        XCTAssertEqual(HorizontalLengthText.millimetres(1_234_567), "1.235 mm")
        XCTAssertEqual(HorizontalLengthText.millimetres(-250_000), "\u{2212}0.250 mm")
        XCTAssertEqual(HorizontalLengthText.millimetres(250_000, signed: true), "+0.250 mm")
        XCTAssertEqual(HorizontalLengthText.millimetres(-0.1, signed: true), "+0.000 mm")
        XCTAssertEqual(HorizontalLengthText.picoseconds(-3.5, signed: true), "\u{2212}3.500 ps")
    }

    // MARK: - The window's list

    func testMeasuringAddsARowPerNetWithItsTracks() {
        let board = [
            track("A", (0, 0), (10, 0), net: tx),
            track("b", (10, 0), (10, 5), net: tx),
            track("c", (0, 1), (8, 1), net: txn),
            track("d", (0, 2), (3, 2), net: nil),
        ]
        var tuning = HorizontalLengthTuning()
        tuning.add(tracks: [board[0], board[2], board[3]], allTracks: false)
        XCTAssertEqual(tuning.rows.map(\.netID), [tx, txn], "a track on no net is left out")
        XCTAssertEqual(tuning.rows.first?.trackIDs, ["a"])

        func row(_ name: String, _ measured: [HorizontalLengthTuning.Measurement]) throws -> HorizontalLengthTuning.Measurement {
            try XCTUnwrap(measured.first { $0.netName == name }, "\(measured.map(\.netName))")
        }
        var measured = tuning.measurements(tracks: board, netDetails: details)
        // By name in Finder's order, which puts TX- before TX+.
        XCTAssertEqual(measured.map(\.netName), ["TX+", "TX-"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(try row("TX+", measured).length, 10 * mm, accuracy: 1e-6, "only the tracks it was added with")
        XCTAssertEqual(try row("TX-", measured).length, 8 * mm, accuracy: 1e-6)
        XCTAssertNil(try row("TX+", measured).lengthDelta, "no reference yet")
        XCTAssertEqual(try row("TX+", measured).partnerID, txn)
        XCTAssertEqual(try row("TX+", measured).fraction, 1)
        XCTAssertEqual(try row("TX-", measured).fraction, 0.8, accuracy: 1e-9)

        // All tracks takes the whole net; a reference gives every row its Δ.
        tuning.rows[0].allTracks = true
        tuning.referenceRowID = tuning.rows[1].id
        measured = tuning.measurements(tracks: board, netDetails: details)
        XCTAssertEqual(try row("TX+", measured).length, 15 * mm, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(try row("TX+", measured).lengthDelta), 7 * mm, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(try row("TX-", measured).lengthDelta), 0, accuracy: 1e-9)
        XCTAssertTrue(try row("TX-", measured).isReference)
        XCTAssertEqual(try XCTUnwrap(tuning.referenceLength(on: board)), 8 * mm, accuracy: 1e-6)

        // A track deleted since counts for nothing.
        measured = tuning.measurements(tracks: Array(board.dropFirst(3)), netDetails: details)
        XCTAssertEqual(try row("TX-", measured).length, 0)

        tuning.remove([tuning.rows[1].id])
        XCTAssertNil(tuning.referenceRowID, "the reference went with its row")
        XCTAssertEqual(tuning.rows.count, 1)
        tuning.clear()
        XCTAssertTrue(tuning.isEmpty)
    }

    func testDelayFollowsTheVelocityFactor() {
        var tuning = HorizontalLengthTuning()
        // 299.79 mm at the speed of light is a nanosecond.
        XCTAssertEqual(tuning.delayPicoseconds(299.79 * mm), 1000, accuracy: 1e-6)
        tuning.relativePermittivity = 4
        XCTAssertEqual(tuning.velocityFactor, 0.5, accuracy: 1e-12, "vf = 1/√εr")
        XCTAssertEqual(tuning.delayPicoseconds(299.79 * mm), 2000, accuracy: 1e-6)
        tuning.velocityFactor = 0.25
        XCTAssertEqual(tuning.relativePermittivity, 16, accuracy: 1e-9)
        tuning.relativePermittivity = 100
        XCTAssertEqual(tuning.velocityFactor, HorizontalLengthTuning.velocityFactorRange.lowerBound, "Horizon's 22% floor")
    }

    @MainActor
    func testTheModelMeasuresTheBoardItIsGiven() throws {
        let model = HorizontalLengthTuningModel()
        var tracks = [track("a", (0, 0), (10, 0), net: tx), track("b", (0, 1), (4, 1), net: txn)]
        model.update(tracks: tracks, netDetails: details)
        model.add(trackIDs: ["A", "b"], allTracks: false)
        XCTAssertEqual(Set(model.measurements.map(\.netName)), ["TX+", "TX-"])
        model.tuning.referenceRowID = model.tuning.rows.first { $0.netID == tx }?.id
        XCTAssertEqual(try XCTUnwrap(model.referenceLength), 10 * mm, accuracy: 1e-6)

        // The board changes under the window: the lengths follow it.
        tracks[0].to.x = 12 * mm
        model.update(tracks: tracks, netDetails: details)
        XCTAssertEqual(try XCTUnwrap(model.measurements.first { $0.netID == tx }?.length), 12 * mm, accuracy: 1e-6)
    }
}
