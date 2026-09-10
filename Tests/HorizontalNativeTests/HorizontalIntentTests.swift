#if os(macOS)
import XCTest
@testable import HorizontalNative

/// The parts of the App Intents surface that do not need Siri to check.
///
/// The intents themselves are thin — each resolves the document in front and
/// calls the dispatch method the automation channel already exposes, which has
/// its own tests. What is new here, and what a spoken request actually depends
/// on, is how a name said out loud turns into one of the design's objects, and
/// how an id a saved shortcut kept turns back into one.
final class HorizontalIntentTests: XCTestCase {
    private let design = [
        HorizontalDesignObjectEntity(kind: .component, name: "R18", detail: "1 kΩ"),
        HorizontalDesignObjectEntity(kind: .component, name: "R180", detail: "10 kΩ"),
        HorizontalDesignObjectEntity(kind: .component, name: "U1", detail: "OPA2188"),
        HorizontalDesignObjectEntity(kind: .net, name: "GND", detail: "default"),
        HorizontalDesignObjectEntity(kind: .net, name: "GND_ANALOG", detail: "default"),
        HorizontalDesignObjectEntity(kind: .net, name: "3V3", detail: "power"),
    ]

    private func names(_ query: String) -> [String] {
        HorizontalDesignObjectQuery.matches(query, in: design).map(\.name)
    }

    /// Speech-to-text does not agree with itself about a reference designator,
    /// so the shapes it produces all have to land on the same component.
    func testAReferenceDesignatorIsFoundHoweverItWasSaid() {
        XCTAssertEqual(names("R18"), ["R18"])
        XCTAssertEqual(names("r18"), ["R18"])
        XCTAssertEqual(names("R 18"), ["R18"])
        XCTAssertEqual(names("  r 1 8 "), ["R18"])
    }

    /// An exact match is not widened. R18 and R180 both contain "r18", and
    /// asking which one when the user said the whole name is a bad question.
    func testAnExactMatchWinsOverOneThatMerelyContainsIt() {
        XCTAssertEqual(names("R18"), ["R18"])
        XCTAssertEqual(Set(names("R1")), ["R18", "R180"], "an inexact one offers both")
    }

    /// Net names carry separators nobody says out loud.
    func testNetNamesMatchWithoutTheirSeparators() {
        XCTAssertEqual(names("GND"), ["GND"], "the exact net, not both grounds")
        XCTAssertEqual(Set(names("gndanalog")), ["GND_ANALOG"])
        // "gnd_" is exact once the separator is dropped, so it is still one
        // net; a query that matches neither name whole offers both.
        XCTAssertEqual(names("gnd_"), ["GND"])
        XCTAssertEqual(Set(names("nd")), ["GND", "GND_ANALOG"])
        XCTAssertEqual(names("3v3"), ["3V3"])
    }

    func testAnEmptyQueryOffersEverythingAndAnUnknownOneOffersNothing() {
        XCTAssertEqual(names("").count, design.count)
        XCTAssertEqual(names("   ").count, design.count)
        XCTAssertEqual(names("C99"), [])
    }

    /// A saved shortcut stores the id and hands it back later, possibly after
    /// the document it came from was closed — so the id has to be enough to
    /// rebuild the entity on its own.
    func testAnIdentifierRoundTripsWithoutTheDocument() throws {
        for entity in design {
            let rebuilt = try XCTUnwrap(HorizontalDesignObjectEntity(id: entity.id))
            XCTAssertEqual(rebuilt.kind, entity.kind)
            XCTAssertEqual(rebuilt.name, entity.name)
        }
        XCTAssertEqual(HorizontalDesignObjectEntity(kind: .component, name: "R18").id, "component:R18")
        XCTAssertEqual(HorizontalDesignObjectEntity(kind: .net, name: "GND").id, "net:GND")
    }

    /// A net whose name contains a colon still round-trips, because the split
    /// takes only the first one.
    func testAnIdentifierKeepsAColonInTheName() throws {
        let entity = HorizontalDesignObjectEntity(kind: .net, name: "BUS:D0")
        let rebuilt = try XCTUnwrap(HorizontalDesignObjectEntity(id: entity.id))
        XCTAssertEqual(rebuilt.name, "BUS:D0")
        XCTAssertEqual(rebuilt.kind, .net)
    }

    func testAMalformedIdentifierIsRefusedRatherThanGuessed() {
        XCTAssertNil(HorizontalDesignObjectEntity(id: ""))
        XCTAssertNil(HorizontalDesignObjectEntity(id: "R18"))
        XCTAssertNil(HorizontalDesignObjectEntity(id: "component:"))
        XCTAssertNil(HorizontalDesignObjectEntity(id: "gate:R18"))
    }

    /// "Both" is the case that exists because of how people ask.
    func testThePaneChoicesMapToPanes() {
        XCTAssertEqual(HorizontalPaneChoice.schematic.panes, [.schematic])
        XCTAssertEqual(HorizontalPaneChoice.board.panes, [.board])
        XCTAssertEqual(HorizontalPaneChoice.both.panes, [.schematic, .board])
    }

    /// With nothing open a query still has to answer. Siri and Shortcuts run
    /// these whenever they like, app running or not.
    @MainActor
    func testNamingObjectsWithNothingOpenIsEmptyRatherThanAnError() {
        // No live document is registered by this test, so the frontmost lookup
        // finds nothing — the same state as the app sitting at its launch
        // screen.
        XCTAssertThrowsError(try HorizontalIntentTarget.current()) { error in
            XCTAssertEqual("\(error)", "\(HorizontalIntentError.noProjectOpen)")
        }
    }
}
#endif
