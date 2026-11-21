import XCTest
@testable import HorizontalNative

/// A route started on a pad a track already leaves continues that track: its
/// width, and whether the width is the rules', as a route started on the
/// track itself does. A bare pad still takes the rules' width.
final class RouteFromPadContinuesItsTrackTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let pad = HorizontalPoint(x: 2_000_000, y: 3_000_000)

    /// One rule, taking every net: 0.5 mm on the top layer.
    private var rules: HorizontalBoardRules {
        let all: JSONDictionary = [
            "mode": "all", "net": "00000000-0000-0000-0000-000000000000",
            "net_class": "00000000-0000-0000-0000-000000000000", "net_name_regex": "",
        ]
        let json: JSONDictionary = [
            "track_width": [
                "all": ["enabled": true, "order": 0, "match": all,
                        "widths": ["0": ["min": 100_000, "max": 10_000_000, "def": 500_000]]],
            ] as JSONDictionary
        ]
        return HorizontalBoardRules(rules: json, netDetails: [:])
    }

    private func track(
        _ id: String, to end: HorizontalPoint, width: Double, layer: Int? = nil, fromRules: Bool = false
    ) -> HorizontalSegment {
        HorizontalSegment(
            id: id, from: pad, to: end, width: width, layer: layer ?? top, netID: "vcc", widthFromRules: fromRules)
    }

    /// The width a route clicked on the pad starts with, as `addDrawTrackPoint` asks for it.
    private func start(explicit: Double? = nil, onPad: Bool = true, tracks: [HorizontalSegment]) -> HorizontalRouteWidth.Resolution {
        let startTrack = BoardTrackRouting.startTrack(at: pad, onPad: onPad, layer: top, tracks: tracks)
        return HorizontalRouteWidth.start(
            explicit: explicit, onPad: onPad, startTrack: startTrack,
            net: "vcc", layer: top, rules: rules, tracks: tracks)
    }

    func testAPadWithOneTrackGivesThatTracksWidth() {
        let existing = track("t", to: HorizontalPoint(x: 5_000_000, y: 3_000_000), width: 330_000)
        let width = start(tracks: [existing])
        XCTAssertEqual(width, .init(width: 330_000, source: .track(id: "t")))
        // A width of the track's own: what the route lays isn't the rules'.
        XCTAssertFalse(width.source.isRule)

        // The track may run to the pad as well as from it.
        var reversed = existing
        reversed.from = existing.to
        reversed.to = pad
        XCTAssertEqual(start(tracks: [reversed]), .init(width: 330_000, source: .track(id: "t")))
    }

    func testAPadWhoseTrackFollowsTheRulesGivesTheRulesWidth() {
        // The track's width is stale; the rule's is the one the route takes,
        // and what it lays follows the rules as the track does.
        let existing = track("t", to: HorizontalPoint(x: 5_000_000, y: 3_000_000), width: 330_000, fromRules: true)
        let width = start(tracks: [existing])
        XCTAssertEqual(width, .init(width: 500_000, source: .rule(id: "all")))
        XCTAssertTrue(width.source.isRule)
    }

    func testAPadWithNoTrackTakesTheRulesWidthAsBefore() {
        XCTAssertNil(BoardTrackRouting.startTrack(at: pad, onPad: true, layer: top, tracks: []))
        XCTAssertEqual(start(tracks: []), .init(width: 500_000, source: .rule(id: "all")))
        // A custom width doesn't hold on a pad.
        XCTAssertEqual(start(explicit: 420_000, tracks: []), .init(width: 500_000, source: .rule(id: "all")))
    }

    func testACustomWidthGivesWayToThePadsTrackAsItDoesToATrack() {
        let existing = track("t", to: HorizontalPoint(x: 5_000_000, y: 3_000_000), width: 330_000)
        let onPad = start(explicit: 420_000, tracks: [existing])
        // The same start on the track itself, off any pad.
        let onTrack = HorizontalRouteWidth.start(
            explicit: 420_000, startTrack: existing, net: "vcc", layer: top, rules: rules, tracks: [existing])
        XCTAssertEqual(onPad, .init(width: 330_000, source: .track(id: "t")))
        XCTAssertEqual(onPad, onTrack)
    }

    func testATrackPassingOverThePadOrOnAnotherLayerDoesNotCount() {
        // Through the pad's center, ending on neither side of it.
        let passing = HorizontalSegment(
            id: "through", from: HorizontalPoint(x: 0, y: 3_000_000), to: HorizontalPoint(x: 5_000_000, y: 3_000_000),
            width: 330_000, layer: top, netID: "vcc")
        let below = track("below", to: HorizontalPoint(x: 5_000_000, y: 3_000_000), width: 330_000, layer: bottom)
        XCTAssertNil(BoardTrackRouting.startTrack(at: pad, onPad: true, layer: top, tracks: [passing, below]))
        XCTAssertEqual(start(tracks: [passing, below]), .init(width: 500_000, source: .rule(id: "all")))
        // Off a pad the track under the point is still the one continued.
        XCTAssertEqual(start(onPad: false, tracks: [passing]), .init(width: 330_000, source: .track(id: "through")))
    }

    func testOfSeveralTracksLeavingThePadTheWidestIsContinued() {
        let narrow = track("narrow", to: HorizontalPoint(x: 5_000_000, y: 3_000_000), width: 200_000)
        let wide = track("wide", to: HorizontalPoint(x: 2_000_000, y: 6_000_000), width: 800_000)
        let alsoWide = track("also-wide", to: HorizontalPoint(x: 0, y: 3_000_000), width: 800_000)
        // Whatever the board's order; of equally wide ones, the first.
        XCTAssertEqual(start(tracks: [narrow, wide, alsoWide]), .init(width: 800_000, source: .track(id: "wide")))
        XCTAssertEqual(start(tracks: [alsoWide, wide, narrow]), .init(width: 800_000, source: .track(id: "also-wide")))
    }
}
