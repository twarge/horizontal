import XCTest
@testable import HorizontalNative

/// Clearance resolution for the router.
///
/// Every case here is a way to put copper closer than the rules allow while the
/// router reports a legal route, which is the one failure the design study says
/// must never happen. The rules distinguish eleven object classes, scope
/// themselves by layer, and keep non-copper and keepouts in separate tables —
/// so the tests are organised by the ways a resolver can quietly read the wrong
/// number, not by API surface.
final class RouterClearanceTests: XCTestCase {
    /// A rule set built from JSON in the shape the board file uses, so these
    /// exercise the real parser rather than hand-made structs.
    private func rules(
        copper: [JSONDictionary] = [],
        copperOther: [JSONDictionary] = [],
        keepout: [JSONDictionary] = []
    ) -> HorizontalBoardRules {
        var value = HorizontalBoardRules.empty
        value.clearanceCopperRules = copper.map { HorizontalRuleClearanceCopper(json: $0) }
        value.clearanceCopperOtherRules = copperOther.map { HorizontalRuleClearanceCopperOther(json: $0) }
        value.clearanceCopperKeepoutRules = keepout.map { HorizontalRuleClearanceCopperKeepout(json: $0) }
        return value
    }

    private func resolver(_ rules: HorizontalBoardRules) -> HorizontalRouterClearances {
        HorizontalRouterClearances(
            rules: rules,
            netIDForCode: [0: "net-a", 1: "net-b", 2: "net-c"]
        )
    }

    /// A copper rule matching everything, with per-class values so a resolver
    /// reading the wrong class is visible in the number.
    private func copperRule(
        layer: Int = 10_000,
        trackTrack: Int = 100_000,
        trackVia: Int = 250_000,
        trackPad: Int = 300_000
    ) -> JSONDictionary {
        [
            "enabled": true,
            "order": 0,
            "layer": layer,
            "match_1": ["mode": "all"],
            "match_2": ["mode": "all"],
            "clearances": [
                ["types": ["track", "track"], "clearance": trackTrack],
                ["types": ["track", "via"], "clearance": trackVia],
                ["types": ["track", "pad"], "clearance": trackPad],
            ],
        ]
    }

    // MARK: - Object class

    /// The gap that motivated this: the world collapsed everything to
    /// track-to-track. A board clearing pads more widely than tracks would then
    /// be routed with the track number and end up too close to every pad.
    func testEachObjectClassGetsItsOwnClearance() {
        let resolve = resolver(rules(copper: [copperRule()]))

        XCTAssertEqual(resolve.clearance(.track, net: 0, .track, net: 1, on: 0), 100_000)
        XCTAssertEqual(resolve.clearance(.track, net: 0, .via, net: 1, on: 0), 250_000)
        XCTAssertEqual(resolve.clearance(.track, net: 0, .pad, net: 1, on: 0), 300_000)
    }

    /// Order must not change the answer, or two call sites disagree about the
    /// same pair.
    func testClearanceIsSymmetricInThePair() {
        let resolve = resolver(rules(copper: [copperRule()]))
        for a in [HorizontalRouterClearances.ObjectClass.track, .pad, .via, .plane] {
            for b in [HorizontalRouterClearances.ObjectClass.track, .pad, .via, .plane] {
                XCTAssertEqual(
                    resolve.clearance(a, net: 0, b, net: 1, on: 0),
                    resolve.clearance(b, net: 1, a, net: 0, on: 0),
                    "\(a) vs \(b)"
                )
            }
        }
    }

    /// A through-hole pad is a distinct rule entry from a surface pad. Reading
    /// the surface number for a through-hole pad is the same class of error.
    func testThroughHolePadIsNotTheSameAsASurfacePad() {
        let rule: JSONDictionary = [
            "enabled": true, "order": 0, "layer": 10_000,
            "match_1": ["mode": "all"], "match_2": ["mode": "all"],
            "clearances": [
                ["types": ["track", "pad"], "clearance": 100_000],
                ["types": ["track", "pad_th"], "clearance": 400_000],
            ],
        ]
        let resolve = resolver(rules(copper: [rule]))

        XCTAssertEqual(resolve.clearance(.track, net: 0, .pad, net: 1, on: 0), 100_000)
        XCTAssertEqual(resolve.clearance(.track, net: 0, .padThroughHole, net: 1, on: 0), 400_000)
    }

    // MARK: - Nets

    /// Copper of one net may touch itself, or a track could never reach its pad.
    func testSameNetCopperNeedsNoClearance() {
        let resolve = resolver(rules(copper: [copperRule()]))
        XCTAssertEqual(resolve.clearance(.track, net: 1, .pad, net: 1, on: 0), 0)
        XCTAssertEqual(resolve.clearance(.track, net: 1, .via, net: 1, on: 0), 0)
    }

    /// Net −1 is "no net", not a net. Two unconnected pieces of copper are not
    /// connected to EACH OTHER, and letting them touch shorts whatever they
    /// later join. This is the same trap the board's connectivity engine had.
    func testNoNetIsNotTreatedAsSameNet() {
        let resolve = resolver(rules(copper: [copperRule()]))
        XCTAssertEqual(
            resolve.clearance(.track, net: -1, .track, net: -1, on: 0), 100_000,
            "two net-less pieces of copper still have to clear each other")
        XCTAssertEqual(resolve.clearance(.track, net: -1, .pad, net: 0, on: 0), 300_000)
    }

    /// A rule naming one net must not leak onto others.
    func testRulesScopedToANetOnlyApplyToThatNet() {
        let specific: JSONDictionary = [
            "enabled": true, "order": 0, "layer": 10_000,
            "match_1": ["mode": "net", "net": "net-a"],
            "match_2": ["mode": "all"],
            "clearances": [["types": ["track", "track"], "clearance": 500_000]],
        ]
        let resolve = resolver(rules(copper: [specific, copperRule()]))

        XCTAssertEqual(resolve.clearance(.track, net: 0, .track, net: 1, on: 0), 500_000, "net-a is special")
        XCTAssertEqual(resolve.clearance(.track, net: 1, .track, net: 2, on: 0), 100_000, "others are not")
    }

    // MARK: - Layers

    /// Rules can be scoped to a layer, and the world resolved them all on top
    /// copper. An inner-layer route then used the top layer's numbers.
    func testLayerScopedRulesApplyOnlyToTheirLayer() {
        let innerOnly: JSONDictionary = [
            "enabled": true, "order": 0,
            "layer": -1,
            "match_1": ["mode": "all"], "match_2": ["mode": "all"],
            "clearances": [["types": ["track", "track"], "clearance": 600_000]],
        ]
        let resolve = resolver(rules(copper: [innerOnly, copperRule()]))

        XCTAssertEqual(resolve.clearance(.track, net: 0, .track, net: 1, on: -1), 600_000)
        XCTAssertEqual(resolve.clearance(.track, net: 0, .track, net: 1, on: 0), 100_000)
        XCTAssertEqual(resolve.clearance(.track, net: 0, .track, net: 1, on: -100), 100_000)
    }

    // MARK: - Non-copper

    /// Board edge, unplated holes and text are not copper and are governed by a
    /// different table. Reading the copper table for them returns a number that
    /// has nothing to do with the rule the board actually states.
    func testNonCopperUsesTheCopperToOtherTable() {
        let other: JSONDictionary = [
            "enabled": true, "order": 0, "layer": 10_000,
            "match": ["mode": "all"],
            "clearances": [
                ["types": ["track", "board_edge"], "clearance": 350_000],
                ["types": ["track", "hole_npth"], "clearance": 450_000],
                // Text is keyed as "other" — see the dedicated test below.
                ["types": ["track", "other"], "clearance": 50_000],
            ],
        ]
        let resolve = resolver(rules(copper: [copperRule()], copperOther: [other]))

        XCTAssertEqual(resolve.clearance(.track, net: 0, .boardEdge, net: -1, on: 0), 350_000)
        XCTAssertEqual(resolve.clearance(.track, net: 0, .holeUnplated, net: -1, on: 0), 450_000)
        XCTAssertEqual(resolve.clearance(.track, net: 0, .text, net: -1, on: 0), 50_000)
    }

    /// A subtlety a router author would get wrong exactly once: the rules fold
    /// text into the generic "other" non-copper class, so a rule keyed on `text`
    /// never matches anything. Asking for text clearance has to return the
    /// `other` number, and this pins that rather than leaving it to be
    /// rediscovered.
    func testTextResolvesThroughTheOtherClass() {
        let other: JSONDictionary = [
            "enabled": true, "order": 0, "layer": 10_000,
            "match": ["mode": "all"],
            "clearances": [
                ["types": ["track", "other"], "clearance": 123_000],
                ["types": ["track", "text"], "clearance": 999_000],
            ],
        ]
        let resolve = resolver(rules(copper: [copperRule()], copperOther: [other]))
        XCTAssertEqual(
            resolve.clearance(.track, net: 0, .text, net: -1, on: 0), 123_000,
            "a rule keyed on `text` is unreachable; `other` is what governs it")
    }

    /// A plated hole IS copper — a via barrel — and must not be sent to the
    /// non-copper table just because it is a hole.
    func testPlatedHolesAreCopperAndUnplatedOnesAreNot() {
        let copperTable: JSONDictionary = [
            "enabled": true, "order": 0, "layer": 10_000,
            "match_1": ["mode": "all"], "match_2": ["mode": "all"],
            "clearances": [["types": ["track", "hole_pth"], "clearance": 275_000]],
        ]
        let otherTable: JSONDictionary = [
            "enabled": true, "order": 0, "layer": 10_000,
            "match": ["mode": "all"],
            "clearances": [["types": ["track", "hole_npth"], "clearance": 475_000]],
        ]
        let resolve = resolver(rules(copper: [copperTable], copperOther: [otherTable]))

        XCTAssertEqual(resolve.clearance(.track, net: 0, .holePlated, net: 1, on: 0), 275_000)
        XCTAssertEqual(resolve.clearance(.track, net: 0, .holeUnplated, net: -1, on: 0), 475_000)
    }

    /// An unplated hole has no net, so a same-net short-circuit must not fire
    /// for it — that would return zero clearance to a mounting hole.
    func testAnUnplatedHoleIsNeverSameNet() {
        let other: JSONDictionary = [
            "enabled": true, "order": 0, "layer": 10_000,
            "match": ["mode": "all"],
            "clearances": [["types": ["track", "hole_npth"], "clearance": 400_000]],
        ]
        let resolve = resolver(rules(copper: [copperRule()], copperOther: [other]))
        XCTAssertEqual(resolve.clearance(.track, net: -1, .holeUnplated, net: -1, on: 0), 400_000)
    }

    // MARK: - Keepouts

    func testKeepoutsUseTheirOwnTableKeyedByClass() {
        let keepout: JSONDictionary = [
            "enabled": true, "order": 0,
            "match": ["mode": "all"],
            "match_keepout": ["mode": "keepout_class", "keepout_class": "no-copper"],
            // Keyed by patch-type name, unlike the copper tables' pair arrays.
            "clearances": ["track": 800_000],
        ]
        let resolve = resolver(rules(copper: [copperRule()], keepout: [keepout]))

        XCTAssertEqual(
            resolve.clearance(.track, net: 0, .keepout("no-copper"), net: -1, on: 0), 800_000)
        XCTAssertEqual(
            resolve.clearance(.keepout("no-copper"), net: -1, .track, net: 0, on: 0), 800_000,
            "and symmetric, like every other pair")
    }

    // MARK: - Broad phase

    /// The broad phase inflates one query hull, so it has to be at least as large
    /// as any exact clearance it might later need. Smaller and the index never
    /// offers the obstacle, so the exact test never runs and the collision is
    /// invisible.
    func testBroadPhaseIsNeverSmallerThanAnyExactClearance() {
        let other: JSONDictionary = [
            "enabled": true, "order": 0, "layer": 10_000,
            "match": ["mode": "all"],
            "clearances": [["types": ["track", "board_edge"], "clearance": 900_000]],
        ]
        let resolve = resolver(rules(copper: [copperRule()], copperOther: [other]))
        let broad = resolve.broadPhaseClearance(forTrackOn: 0, layer: 0)

        for target in [HorizontalRouterClearances.ObjectClass.track, .pad, .padThroughHole,
                       .via, .plane, .holePlated, .holeUnplated, .text, .boardEdge] {
            for net in [-1, 0, 1, 2] {
                XCTAssertLessThanOrEqual(
                    resolve.clearance(.track, net: 0, target, net: net, on: 0), broad,
                    "broad phase must cover \(target) on net \(net)")
            }
        }
        XCTAssertGreaterThanOrEqual(broad, 900_000, "and cover the widest rule on the board")
    }

    // MARK: - Defaults

    /// With no rules at all the resolver must still return the board's default
    /// rather than zero. Zero would let the router lay copper on copper.
    func testAnEmptyRuleSetFallsBackToTheDefaultClearance() {
        let resolve = resolver(rules())
        let value = resolve.clearance(.track, net: 0, .track, net: 1, on: 0)
        XCTAssertGreaterThan(value, 0, "no rules must not mean no clearance")
    }
}
