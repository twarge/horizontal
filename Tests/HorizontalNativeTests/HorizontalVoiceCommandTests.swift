import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Voice control without a microphone: how a name said out loud turns into
/// one of the design's objects, how a sentence turns into a command, and what
/// running the command does to a registered document. The one test that needs
/// the speech model is opt-in.
final class HorizontalVoiceCommandTests: XCTestCase {
    private let design = [
        HorizontalDesignObject(kind: .component, name: "R18", detail: "1 kΩ"),
        HorizontalDesignObject(kind: .component, name: "R180", detail: "10 kΩ"),
        HorizontalDesignObject(kind: .component, name: "U1", detail: "OPA2188"),
        HorizontalDesignObject(kind: .net, name: "GND", detail: "default"),
        HorizontalDesignObject(kind: .net, name: "GND_ANALOG", detail: "default"),
        HorizontalDesignObject(kind: .net, name: "3V3", detail: "power"),
    ]

    /// A design where the same number belongs to more than one kind of part,
    /// and where a net's name starts with a word that is also a kind.
    private let parts = [
        HorizontalDesignObject(kind: .component, name: "C123", detail: "100 nF"),
        HorizontalDesignObject(kind: .component, name: "C124", detail: "100 nF"),
        HorizontalDesignObject(kind: .component, name: "R123", detail: "1 kΩ"),
        HorizontalDesignObject(kind: .component, name: "R12", detail: "10 kΩ"),
        HorizontalDesignObject(kind: .component, name: "TP5", detail: ""),
        HorizontalDesignObject(kind: .component, name: "U3", detail: "STM32"),
        HorizontalDesignObject(kind: .net, name: "GND", detail: "default"),
        HorizontalDesignObject(kind: .net, name: "LED Red", detail: "default"),
        HorizontalDesignObject(kind: .net, name: "RESET", detail: "default"),
        HorizontalDesignObject(kind: .net, name: "+3.3V_DIG", detail: "power"),
        HorizontalDesignObject(kind: .net, name: "+3.3V_PLL", detail: "power"),
    ]

    private func names(_ query: String) -> [String] {
        HorizontalSpokenMatcher.matches(query, in: design).map(\.name)
    }

    private func within(_ family: HorizontalObjectFamily, _ answer: String) -> [String] {
        HorizontalSpokenMatcher.matches(answer, family: family, in: parts).map(\.name)
    }

    private func said(_ query: String) -> [String] {
        HorizontalSpokenMatcher.matches(query, in: parts).map(\.name)
    }

    // MARK: - Names

    /// Speech-to-text does not agree with itself about a reference designator,
    /// so the shapes it produces all have to land on the same component.
    func testAReferenceDesignatorIsFoundHoweverItWasSaid() {
        XCTAssertEqual(names("R18"), ["R18"])
        XCTAssertEqual(names("r18"), ["R18"])
        XCTAssertEqual(names("R 18"), ["R18"])
        XCTAssertEqual(names("  r 1 8 "), ["R18"])
        XCTAssertEqual(names("R18"), ["R18"], "an exact match is not widened to R180")
        XCTAssertEqual(Set(names("R1")), ["R18", "R180"], "an inexact one offers both")
    }

    /// Net names carry separators nobody says out loud.
    func testNetNamesMatchWithoutTheirSeparators() {
        XCTAssertEqual(names("GND"), ["GND"], "the exact net, not both grounds")
        XCTAssertEqual(Set(names("gndanalog")), ["GND_ANALOG"])
        XCTAssertEqual(names("gnd_"), ["GND"])
        XCTAssertEqual(Set(names("nd")), ["GND", "GND_ANALOG"])
        XCTAssertEqual(names("3v3"), ["3V3"])
        XCTAssertEqual(names("").count, design.count)
        XCTAssertEqual(names("C99"), [])
    }

    /// "Highlight capacitor 123": the number is read within the kind, so R123
    /// is not offered alongside C123 — unless the kind is the wide one.
    func testANumberIsReadWithinTheKindThatWasAsked() {
        XCTAssertEqual(within(.capacitor, "123"), ["C123"])
        XCTAssertEqual(within(.resistor, "123"), ["R123"])
        XCTAssertEqual(within(.resistor, "12"), ["R12"], "the whole number, not a prefix of one")
        XCTAssertEqual(Set(within(.component, "123")), ["C123", "R123"])
        XCTAssertEqual(within(.capacitor, "5"), [], "there is no capacitor 5, and TP5 is not one")
        XCTAssertEqual(within(.testPoint, "5"), ["TP5"])
        XCTAssertEqual(within(.net, "123"), [], "a net is named, not numbered")
    }

    /// What the answer says wins over the kind that was asked.
    func testWhatTheAnswerSaysWinsOverTheKindThatWasAsked() {
        XCTAssertEqual(within(.resistor, "C 123"), ["C123"])
        XCTAssertEqual(within(.component, "capacitor 123"), ["C123"])
        XCTAssertEqual(within(.capacitor, "capacitor 123"), ["C123"])
        XCTAssertEqual(within(.net, "ground"), ["GND"])
        XCTAssertEqual(within(.net, "LED red"), ["LED Red"])
        XCTAssertEqual(within(.net, "reset"), ["RESET"], "\"res\" is a kind only as a whole word")
        XCTAssertEqual(Set(within(.capacitor, "")), ["C123", "C124"], "no answer at all offers the kind's whole list")
    }

    /// A kind said in words, with nothing else to go on.
    func testAKindSaidInWordsIsUnderstood() {
        XCTAssertEqual(said("capacitor 123"), ["C123"])
        XCTAssertEqual(said("cap123"), ["C123"], "the kind and the number run together")
        XCTAssertEqual(said("test point 5"), ["TP5"])
        XCTAssertEqual(said("chip 3"), ["U3"])
        XCTAssertEqual(Set(said("capacitors")), ["C123", "C124"], "just the kind offers all of it")
        XCTAssertEqual(Set(said("123")), ["C123", "R123"], "a bare number is a component's number first")
        XCTAssertEqual(said("ground"), ["GND"])
        XCTAssertEqual(said("LED Red"), ["LED Red"])
        XCTAssertEqual(Set(said("3.3 volts")), ["+3.3V_DIG", "+3.3V_PLL"])
        XCTAssertEqual(said("3.3 volts PLL"), ["+3.3V_PLL"])
    }

    /// Net names as people say them, against net names as designs write
    /// them. Both sides go through the same reduction, so each pair here only
    /// has to land on the same string.
    func testANetNameIsMatchedTheWayItIsSaid() {
        func same(_ said: String, _ written: String, _ note: String = "", file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(HorizontalSpokenMatcher.spoken(said), HorizontalSpokenMatcher.spoken(written), note, file: file, line: line)
        }
        same("3.3 volts", "3V3", "a rail said with its decimal is the rail written without")
        same("3.3V", "3V3")
        same("3 point 3 volts", "3V3", "dictation writes digits; the decimal may still come as a word")
        same("5 volts", "5.0V")
        same("plus 5 volts", "+5V")
        same("plus 5 volts", "P5V", "the P of a rail's name is its sign")
        same("minus 5 volts A", "N5VA")
        same("negative 17 volts", "N17V")
        same("P 2.5 V A", "P2.5VA")
        same("1.8 volts FPGA", "1V8_FPGA")
        same("1.8", "1V8", "even without the unit")
        same("ground", "GND")
        same("analog ground", "AGND")
        same("digital ground", "DGND")
        same("relay ground coil plus", "Relay Ground Coil +", "a sign said on its own is a word")
        same("relay ground coil minus", "Relay Ground Coil -")
        same("BBI minus", "BBI-")
        same("USB D plus", "USB_D+")
        same("minus fil", "-FIL", "a sign in front of a word is a word too")
        same("LED red", "LED-Red", "but a dash between words is nothing")
        same("DAC chip select", "DAC_CS")
        same("UC reset", "UC_RST")
        same("DAC reset", "DAC_RESET", "the written-out word and its abbreviation are one")
        same("relay ground enable", "Relay Ground Enable")
        same("serial transmit", "Serial TX")
        same("ADC input", "ADC Input")
        same("ADC MCLK 16 megahertz", "ADC MCLK 16 MHz")
        same("clock 1 megahertz", "Clock 1 MHz")
        XCTAssertNotEqual(HorizontalSpokenMatcher.spoken("3V3"), HorizontalSpokenMatcher.spoken("3V"), "different rails stay different")
        XCTAssertNotEqual(HorizontalSpokenMatcher.spoken("P5V"), HorizontalSpokenMatcher.spoken("N5V"))
        XCTAssertNotEqual(HorizontalSpokenMatcher.spoken("Relay Ground Coil +"), HorizontalSpokenMatcher.spoken("Relay Ground Coil -"))
    }

    /// The reference-designator conventions the kinds stand for, from a tally
    /// of the pools: disjoint, so a number is one kind's or another's.
    func testTheKindsCoverTheUsualPrefixesAndDoNotOverlap() {
        XCTAssertTrue(HorizontalObjectFamily.capacitor.covers(refdes: "C7"))
        XCTAssertFalse(HorizontalObjectFamily.capacitor.covers(refdes: "CN7"), "CN is a connector")
        XCTAssertTrue(HorizontalObjectFamily.connector.covers(refdes: "CN7"))
        XCTAssertTrue(HorizontalObjectFamily.integratedCircuit.covers(refdes: "U12"))
        XCTAssertTrue(HorizontalObjectFamily.component.covers(refdes: "MP3"), "the wide kind takes any prefix")
        XCTAssertTrue(HorizontalObjectFamily.mechanical.covers(refdes: "MP3"))
        XCTAssertTrue(HorizontalObjectFamily.switch.covers(refdes: "S2"), "the horizon pool files switches under S")
        XCTAssertTrue(HorizontalObjectFamily.crystal.covers(refdes: "X1"), "…and oscillators under X")
        XCTAssertTrue(HorizontalObjectFamily.fiducial.covers(refdes: "A1"), "…and fiducials under A")
        XCTAssertTrue(HorizontalObjectFamily.resistor.covers(refdes: "RV2"), "a trimmer is a resistor here")
        XCTAssertFalse(HorizontalObjectFamily.net.covers(refdes: "R1"))
        for family in HorizontalObjectFamily.allCases where family != .component && family != .net {
            for prefix in family.prefixes {
                let owners = HorizontalObjectFamily.allCases.filter { $0.prefixes.contains(prefix) }
                XCTAssertEqual(owners, [family], "prefix \(prefix) belongs to one kind")
            }
        }
        XCTAssertEqual(HorizontalSpokenMatcher.prefix(of: "TP12"), "TP")
        XCTAssertEqual(HorizontalSpokenMatcher.number(of: "TP12"), "12")
        XCTAssertEqual(HorizontalSpokenMatcher.number(of: "SHIELD"), "")
    }

    // MARK: - Sentences

    private var vocabulary: HorizontalVoiceVocabulary {
        HorizontalVoiceVocabulary(objects: parts, sheetNames: ["Interface", "Microcontroller", "Isolated Power"])
    }

    private func parse(_ sentence: String) -> HorizontalVoiceCommand {
        HorizontalVoiceCommandParser.parse(sentence, vocabulary: vocabulary)
    }

    private func object(_ name: String) -> HorizontalDesignObject {
        parts.first { $0.name == name }!
    }

    /// The verbs, each in the shapes speech produces for it.
    func testASentenceNamesAVerbAndAThing() {
        XCTAssertEqual(parse("Highlight C123."), .highlight([object("C123")]))
        XCTAssertEqual(parse("highlight c 123"), .highlight([object("C123")]))
        XCTAssertEqual(parse("Highlight capacitor 123 in Horizontal"), .highlight([object("C123")]))
        XCTAssertEqual(parse("Show me the reset net"), .highlight([object("RESET")]), "the wide kind said after the name")
        XCTAssertEqual(parse("please highlight ground"), .highlight([object("GND")]))
        XCTAssertEqual(parse("light up test point 5"), .highlight([object("TP5")]))
        XCTAssertEqual(parse("select R12"), .select([object("R12")]))
        XCTAssertEqual(parse("Zoom to U3"), .zoom([object("U3")], pane: nil))
        XCTAssertEqual(parse("go to C124 on the board"), .zoom([object("C124")], pane: .board))
        XCTAssertEqual(parse("find the LED red net in the schematic"), .zoom([object("LED Red")], pane: .schematic))
        XCTAssertEqual(parse("where is R12?"), .zoom([object("R12")], pane: nil))
        XCTAssertEqual(parse("clear the highlight"), .clearHighlight)
        XCTAssertEqual(parse("clear"), .clearHighlight)
        XCTAssertEqual(parse("unhighlight"), .clearHighlight)
        XCTAssertEqual(parse("clear the selection"), .clearSelection)
        XCTAssertEqual(parse("deselect"), .clearSelection)
        XCTAssertEqual(parse("undo"), .undo)
        XCTAssertEqual(parse("Undo that"), .undo)
        XCTAssertEqual(parse("redo"), .redo)
    }

    /// A kind alone highlights all of it; a number two kinds share is a
    /// question back; a name nobody has is said back with the kind.
    func testSeveralThingsAreHandledHonestly() {
        XCTAssertEqual(parse("highlight the capacitors"), .highlight([object("C123"), object("C124")]))
        XCTAssertEqual(parse("select all capacitors"), .select([object("C123"), object("C124")]))
        XCTAssertEqual(parse("highlight 123"), .ambiguous([object("C123"), object("R123")], said: "123"))
        XCTAssertEqual(parse("zoom to the capacitors"), .zoom([object("C123"), object("C124")], pane: nil), "several are framed together")
        XCTAssertEqual(parse("highlight capacitor 7"), .nothingNamed(said: "7", family: .capacitor))
        XCTAssertEqual(parse("highlight the ground net"), .highlight([object("GND")]), "a wide kind after the name scopes it")
        XCTAssertEqual(parse("highlight the nets"), .highlight(parts.filter { $0.kind == .net }), "a wide kind alone is all of it")
        XCTAssertEqual(parse("highlight the flux capacitor"), .nothingNamed(said: "flux capacitor", family: nil))
        XCTAssertEqual(parse("highlight"), .unrecognized, "no thing yet — the rest may still be coming")
        XCTAssertEqual(parse("what time is it"), .unrecognized)
        XCTAssertEqual(parse(""), .unrecognized)
    }

    /// A name buried in transcription noise is still found, as long as it is
    /// in there exactly: the longest run of words that names something wins,
    /// and a run that names several is still a question back.
    func testANameIsFoundInsideANoisySentence() {
        XCTAssertEqual(parse("zoom to xyz C 123"), .zoom([object("C123")], pane: nil))
        XCTAssertEqual(parse("highlight um R 12 okay"), .highlight([object("R12")]))
        XCTAssertEqual(parse("select the blah capacitor 124"), .select([object("C124")]))
        XCTAssertEqual(parse("zoom to the thing near test point 5 on the board"), .zoom([object("TP5")], pane: .board))
        XCTAssertEqual(parse("highlight xyz 123"), .ambiguous([object("C123"), object("R123")], said: "xyz 123"))
        XCTAssertEqual(parse("highlight xyz abc"), .nothingNamed(said: "xyz abc", family: nil), "noise alone is still nothing")
    }

    /// Transcription bends a verb — "highlights", "highlighting", "selected"
    /// — and drops a word of its own between the verb and the name. Both are
    /// read as what was meant.
    func testAVerbIsReadInAnyInflectionAndPastAFillerWord() {
        XCTAssertEqual(parse("highlights C123"), .highlight([object("C123")]))
        XCTAssertEqual(parse("Highlighting C123"), .highlight([object("C123")]))
        XCTAssertEqual(parse("highlighted C123"), .highlight([object("C123")]))
        XCTAssertEqual(parse("selects R12"), .select([object("R12")]))
        XCTAssertEqual(parse("selecting the capacitors"), .select([object("C123"), object("C124")]))
        XCTAssertEqual(parse("zooms to U3"), .zoom([object("U3")], pane: nil))
        XCTAssertEqual(parse("zooming in"), .zoomBy(2, pane: nil))
        XCTAssertEqual(parse("zoomed out"), .zoomBy(0.5, pane: nil))
        XCTAssertEqual(parse("shows the board"), .showPanes([.board]))
        XCTAssertEqual(parse("showing sheet 2"), .showSheet(.number(2)))
        XCTAssertEqual(parse("finds R12"), .zoom([object("R12")], pane: nil))
        XCTAssertEqual(parse("found R12"), .zoom([object("R12")], pane: nil))
        XCTAssertEqual(parse("goes to TP5"), .zoom([object("TP5")], pane: nil))
        XCTAssertEqual(parse("went to TP5"), .zoom([object("TP5")], pane: nil))
        XCTAssertEqual(parse("lights up test point 5"), .highlight([object("TP5")]))
        XCTAssertEqual(parse("lit up test point 5"), .highlight([object("TP5")]))
        XCTAssertEqual(parse("hides the 3D view"), .hidePanes([.threeD]))
        XCTAssertEqual(parse("clears the highlight"), .clearHighlight)

        XCTAssertEqual(parse("highlight what C123"), .highlight([object("C123")]))
        XCTAssertEqual(parse("highlight what? C123"), .highlight([object("C123")]))
        XCTAssertEqual(parse("highlights what C123"), .highlight([object("C123")]))
        XCTAssertEqual(parse("highlight um what C123"), .highlight([object("C123")]))
        XCTAssertEqual(parse("select uh R12"), .select([object("R12")]))
        XCTAssertEqual(parse("zoom to like U3"), .zoom([object("U3")], pane: nil))
        XCTAssertEqual(parse("highlight what connects C123 and R12"), .among(.highlight, [object("C123"), object("R12")]), "a question is still a question")
        XCTAssertEqual(parse("highlight what"), .unrecognized, "a verb and a filler: the name may still be coming")
        XCTAssertEqual(parse("highlights"), .unrecognized)
    }

    /// The conversation remembers. After a thing is named, a bare verb or a
    /// pronoun means it; a bare name means the last verb; and with nothing
    /// remembered, "zoom" fits the whole view and "it" is a question back.
    func testABareVerbOrAPronounMeansTheLastThingNamed() {
        var remembered = vocabulary
        remembered.previousSubject = [object("C123")]
        remembered.previousVerb = .highlight
        func parse(_ sentence: String) -> HorizontalVoiceCommand {
            HorizontalVoiceCommandParser.parse(sentence, vocabulary: remembered)
        }
        XCTAssertEqual(parse("zoom"), .zoom([object("C123")], pane: nil))
        XCTAssertEqual(parse("zoom to fit"), .zoom([object("C123")], pane: nil))
        XCTAssertEqual(parse("zoom to it"), .zoom([object("C123")], pane: nil))
        XCTAssertEqual(parse("zoom to it on the board"), .zoom([object("C123")], pane: .board))
        XCTAssertEqual(parse("zoom in on it"), .zoom([object("C123")], pane: nil))
        XCTAssertEqual(parse("fit"), .zoom([object("C123")], pane: nil))
        XCTAssertEqual(parse("highlight it"), .highlight([object("C123")]))
        XCTAssertEqual(parse("select that"), .select([object("C123")]))
        XCTAssertEqual(parse("select"), .select([object("C123")]), "a bare verb takes the last thing")
        XCTAssertEqual(parse("R12"), .highlight([object("R12")]), "a bare name takes the last verb")
        XCTAssertEqual(parse("capacitor 124"), .highlight([object("C124")]))
        XCTAssertEqual(parse("123"), .ambiguous([object("C123"), object("R123")], said: "123"))
        XCTAssertEqual(parse("zoom to everything"), .zoomBy(0, pane: nil), "the whole view, whatever was named")
        XCTAssertEqual(parse("zoom to the whole board"), .zoomBy(0, pane: .board))
        XCTAssertEqual(parse("zoom in"), .zoomBy(2, pane: nil), "a step is still a step")

        remembered.previousSubject = [object("C123"), object("C124")]
        XCTAssertEqual(parse("zoom"), .zoom([object("C123"), object("C124")], pane: nil), "several remembered are framed together")
        XCTAssertEqual(parse("highlight them"), .highlight([object("C123"), object("C124")]))
        XCTAssertEqual(parse("highlight the nets connecting them"), .among(.highlight, [object("C123"), object("C124")]))
        XCTAssertEqual(parse("highlight nets between them"), .among(.highlight, [object("C123"), object("C124")]))
        XCTAssertEqual(parse("select what connects them"), .among(.select, [object("C123"), object("C124")]))
        XCTAssertEqual(self.parse("highlight the nets between them"), .noSubject(.highlight), "nothing remembered")

        XCTAssertEqual(self.parse("zoom"), .zoomBy(0, pane: nil), "nothing remembered: fit the view")
        XCTAssertEqual(self.parse("zoom to fit"), .zoomBy(0, pane: nil))
        XCTAssertEqual(self.parse("zoom to it"), .noSubject(.zoom))
        XCTAssertEqual(self.parse("highlight it"), .noSubject(.highlight))
        XCTAssertEqual(self.parse("R12"), .unrecognized, "no verb yet: a name alone waits")
    }

    /// "The nets between C48 and C50" is what the two share; "C48 and C50"
    /// is both of them.
    func testTwoThingsCanBeNamedTogether() {
        XCTAssertEqual(parse("highlight the nets between C123 and R123"), .among(.highlight, [object("C123"), object("R123")]))
        XCTAssertEqual(parse("highlight the net between capacitor 123 and R 123"), .among(.highlight, [object("C123"), object("R123")]))
        XCTAssertEqual(parse("highlight what connects C123 and R12"), .among(.highlight, [object("C123"), object("R12")]))
        XCTAssertEqual(parse("select the connections from C123 to R12"), .among(.select, [object("C123"), object("R12")]))
        XCTAssertEqual(parse("zoom to the net between C123 and TP5"), .among(.zoom, [object("C123"), object("TP5")]))
        XCTAssertEqual(parse("highlight the nets between C123 and C9"), .nothingNamed(said: "c9", family: nil), "a side nobody has is said back")
        XCTAssertEqual(parse("highlight C123 and R12"), .highlight([object("C123"), object("R12")]))
        XCTAssertEqual(parse("select C123, R12 and TP5"), .select([object("C123"), object("R12"), object("TP5")]))
        XCTAssertEqual(parse("highlight the capacitors and R12"), .highlight([object("C123"), object("C124"), object("R12")]))
        XCTAssertEqual(parse("zoom to C123 and R12"), .zoom([object("C123"), object("R12")], pane: nil), "framed together")
        XCTAssertEqual(parse("zoom to C123, R12, and TP5"), .zoom([object("C123"), object("R12"), object("TP5")], pane: nil))
        XCTAssertEqual(parse("highlight the nets between C123, R123 and TP5"), .among(.highlight, [object("C123"), object("R123"), object("TP5")]))
        XCTAssertEqual(parse("highlight the nets among C123 and R12"), .among(.highlight, [object("C123"), object("R12")]))
    }

    /// Board layer views by name. "The bottom layer" is that side's layers;
    /// "the bottom", "the board bottom", "bottom view" is the side itself,
    /// seen from below — so it mirrors — and a mode alone takes the side that
    /// is up.
    func testLayerViewsAreAskedForByName() {
        XCTAssertEqual(parse("show the top layer"), .showLayers(.topPlacement))
        XCTAssertEqual(parse("show the bottom layer"), .showLayers(.bottomPlacement))
        XCTAssertEqual(parse("show the top silkscreen"), .showLayers(.topSilkscreen))
        XCTAssertEqual(parse("show top routing"), .showLayers(.topRouting))
        XCTAssertEqual(parse("show the bottom copper"), .showLayers(.bottomRouting))
        XCTAssertEqual(parse("show all layers"), .showLayers(.all))
        XCTAssertEqual(parse("show every layer"), .showLayers(.all))
        XCTAssertEqual(parse("copper only"), .showLayers(.copperOnly))
        XCTAssertEqual(parse("show the clean view"), .showLayers(.clean))
        XCTAssertEqual(parse("show the board"), .showPanes([.board]), "a pane is not a layer")

        XCTAssertEqual(parse("show the top"), .showLayers(.topView), "after a show verb the side alone is the side's view")
        XCTAssertEqual(parse("show the bottom"), .showLayers(.bottomView))
        XCTAssertEqual(parse("show the board bottom"), .showLayers(.bottomView))
        XCTAssertEqual(parse("show the bottom of the board"), .showLayers(.bottomView))
        XCTAssertEqual(parse("show top side"), .showLayers(.topView))
        XCTAssertEqual(parse("view from the bottom"), .showLayers(.bottomView))
        XCTAssertEqual(parse("flip the board"), .showLayers(.flipView))
        XCTAssertEqual(parse("show silkscreen"), .showLayers(.silkscreen), "the side that is up decides")
        XCTAssertEqual(parse("show the routing"), .showLayers(.routing))
        XCTAssertEqual(parse("show placement"), .showLayers(.placement))
        XCTAssertEqual(parse("highlight top"), .nothingNamed(said: "top", family: nil), "elsewhere a side is a name")
    }

    /// "Zoom in" and "zoom out" are the view, not a thing; a pane after "on"
    /// picks which, and a thing after "on" is zoom-to.
    func testZoomStepsAreTheViewNotAThing() {
        XCTAssertEqual(parse("zoom in"), .zoomBy(2, pane: nil))
        XCTAssertEqual(parse("zoom out"), .zoomBy(0.5, pane: nil))
        XCTAssertEqual(parse("zoom in a lot"), .zoomBy(4, pane: nil))
        XCTAssertEqual(parse("zoom way out"), .zoomBy(0.25, pane: nil))
        XCTAssertEqual(parse("zoom in a little"), .zoomBy(1.4, pane: nil))
        XCTAssertEqual(parse("zoom in on the board"), .zoomBy(2, pane: .board))
        XCTAssertEqual(parse("zoom out of the 3D view"), .zoomBy(0.5, pane: .threeD))
        XCTAssertEqual(parse("closer"), .zoomBy(2, pane: nil))
        XCTAssertEqual(parse("zoom in on C123"), .zoom([object("C123")], pane: nil))
    }

    /// The presets know their side, whether they mirror, and how a side-less
    /// one resolves against the side that is up.
    func testLayerPresetsResolveAgainstTheSideThatIsUp() {
        XCTAssertEqual(HorizontalBoardLayerPreset.silkscreen.resolved(for: .bottom), .bottomSilkscreen)
        XCTAssertEqual(HorizontalBoardLayerPreset.routing.resolved(for: .top), .topRouting)
        XCTAssertEqual(HorizontalBoardLayerPreset.placement.resolved(for: .bottom), .bottomPlacement)
        XCTAssertEqual(HorizontalBoardLayerPreset.flipView.resolved(for: .top), .bottomView)
        XCTAssertEqual(HorizontalBoardLayerPreset.flipView.resolved(for: .bottom), .topView)
        XCTAssertEqual(HorizontalBoardLayerPreset.topPlacement.resolved(for: .bottom), .topPlacement, "a sided preset keeps its side")
        XCTAssertEqual(HorizontalBoardLayerPreset.bottomView.mirrorsView, true)
        XCTAssertEqual(HorizontalBoardLayerPreset.topView.mirrorsView, false)
        XCTAssertNil(HorizontalBoardLayerPreset.bottomPlacement.mirrorsView, "a layer view leaves the mirror alone")
        XCTAssertEqual(HorizontalBoardLayerPreset.bottomSilkscreen.side, .bottom)
        XCTAssertNil(HorizontalBoardLayerPreset.all.side)

        var options = BoardDisplayOptions()
        XCTAssertNil(options.visibleSide, "everything showing belongs to no side")
        options.applyLayerPreset(.topPlacement)
        XCTAssertEqual(options.visibleSide, .top)
        options.applyLayerPreset(.bottomSilkscreen)
        XCTAssertEqual(options.visibleSide, .bottom)
        options.applyLayerPreset(.all)
        XCTAssertNil(options.visibleSide)
    }

    /// A viewport seen from below runs x the other way and frames the same
    /// point to the same place on screen either way round.
    func testAMirroredViewportRunsTheOtherWay() {
        let bounds = HorizontalRect(points: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 100, y: 50)])
        let size = CGSize(width: 400, height: 200)
        let none = HorizontalCanvasInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        let plain = HorizontalCanvasTransform(bounds: bounds, size: size, fitInsets: none)
        let mirrored = HorizontalCanvasTransform(bounds: bounds, size: size, fitInsets: none, mirrored: true)
        let left = HorizontalPoint(x: 10, y: 25)
        XCTAssertEqual(plain.point(left).x, 40, accuracy: 0.001)
        XCTAssertEqual(mirrored.point(left).x, 360, accuracy: 0.001, "the left edge of the board is on the right")
        XCTAssertEqual(mirrored.point(left).y, plain.point(left).y, accuracy: 0.001, "y is untouched")
        let back = mirrored.worldPoint(mirrored.point(left))
        XCTAssertEqual(back.x, left.x, accuracy: 0.001)
        XCTAssertEqual(back.y, left.y, accuracy: 0.001)

        let target = HorizontalRect(points: [HorizontalPoint(x: 70, y: 10), HorizontalPoint(x: 90, y: 20)])
        let framed = CanvasViewport.framing(target, in: mirrored)
        XCTAssertTrue(framed.mirrored, "framing keeps the side")
        let after = HorizontalCanvasTransform(bounds: bounds, size: size, fitInsets: none, zoom: framed.zoom, pan: framed.pan, mirrored: true)
        XCTAssertEqual(after.point(target.center).x, 200, accuracy: 0.01, "the target is centred")
        XCTAssertEqual(after.point(target.center).y, 100, accuracy: 0.01)
    }

    /// Panes: each, in combination, and hidden.
    func testPanesAreShownAndHidden() {
        XCTAssertEqual(parse("show the board"), .showPanes([.board]))
        XCTAssertEqual(parse("Show me the schematic."), .showPanes([.schematic]))
        XCTAssertEqual(parse("show 3D"), .showPanes([.threeD]))
        XCTAssertEqual(parse("show the 3D board"), .showPanes([.threeD]))
        XCTAssertEqual(parse("show three d"), .showPanes([.threeD]))
        XCTAssertEqual(parse("open the schematic and the board"), .showPanes([.schematic, .board]))
        XCTAssertEqual(parse("show both"), .showPanes([.schematic, .board]))
        XCTAssertEqual(parse("show everything"), .showPanes([.schematic, .board, .threeD]))
        XCTAssertEqual(parse("switch to the parts list"), .showPanes([.parts]))
        XCTAssertEqual(parse("board"), .showPanes([.board]), "a pane on its own is a request to see it")
        XCTAssertEqual(parse("hide the 3D view"), .hidePanes([.threeD]))
        XCTAssertEqual(parse("close the board"), .hidePanes([.board]))
        XCTAssertEqual(parse("show me C123"), .highlight([object("C123")]), "a thing after \"show me\" is a highlight")
    }

    /// Sheets by number, by name, and relative to the one showing.
    func testSheetsAreAskedForInEveryWay() {
        XCTAssertEqual(parse("show sheet 3"), .showSheet(.number(3)))
        XCTAssertEqual(parse("go to sheet three"), .showSheet(.number(3)))
        XCTAssertEqual(parse("sheet 2"), .showSheet(.number(2)))
        XCTAssertEqual(parse("open the isolated power sheet"), .showSheet(.named("isolated power")))
        XCTAssertEqual(parse("show sheet microcontroller"), .showSheet(.named("microcontroller")))
        XCTAssertEqual(parse("next sheet"), .showSheet(.next))
        XCTAssertEqual(parse("go to the next page"), .showSheet(.next))
        XCTAssertEqual(parse("previous sheet"), .showSheet(.previous))
        XCTAssertEqual(parse("show the last sheet"), .showSheet(.last))
        XCTAssertEqual(parse("first sheet"), .showSheet(.first))
    }

    // MARK: - Running

    /// A registered document with a net and two sheets, wired the way the
    /// workspaces wire theirs for the verbs voice control uses.
    @MainActor
    private func liveDocument() throws -> (target: HorizontalCommandTarget.Target, selection: () -> HorizontalLiveSelection, shownSheets: () -> [String], layerPresets: () -> [HorizontalBoardLayerPreset], cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-voice-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        let project = try HorizontalProject.load(from: url)
        let archive = try HorizontalProjectArchive.snapshot(from: url)
        let document = HorizontalLiveDocument(url: url, title: "Untitled", project: project, archive: archive)
        var current = project
        var currentArchive = archive
        var revision = 0
        var selection = HorizontalLiveSelection(panes: ["schematic"])
        var shownSheets: [String] = []
        var currentSheet: String? = nil
        document.currentProject = { current }
        document.archive = { currentArchive }
        document.revision = { String(revision) }
        document.selection = { selection }
        document.setHighlight = { nets, components in
            selection.highlightedNetIDs = nets
            selection.highlightedComponentIDs = components
        }
        document.setSelection = { nets, components in
            selection.netIDs = nets
            selection.componentIDs = components
        }
        document.setPanes = { panes in selection.panes = panes.map(\.rawValue).sorted() }
        document.showSheet = { _, sheetID in
            shownSheets.append(sheetID)
            currentSheet = sheetID
        }
        document.currentSheet = { currentSheet }
        var layerPresets: [HorizontalBoardLayerPreset] = []
        document.setLayerPreset = { layerPresets.append($0) }
        document.zoomBy = { pane, factor in layerPresets.append(factor > 1 ? .topView : .bottomView) }
        document.applyArchive = { edited, _ in
            currentArchive = edited
            current = try HorizontalDispatchSession.project(
                from: HorizontalDispatchSnapshot(archive: edited, baseURL: project.baseURL), url: project.url
            )
            revision += 1
        }
        let session = HorizontalDispatchSession.shared
        let handle = session.registerLive(document)
        let target = try XCTUnwrap(HorizontalCommandTarget.target(handle: handle))
        // A new project has nothing to name; give it a net through the channel.
        let expected = try session.perform { try $0.entry(handle: handle).revision }
        let added = HorizontalDispatch.call([
            "jsonrpc": "2.0", "id": 1, "method": "apply",
            "params": ["handle": handle, "expected_revision": expected, "operation_id": UUID().uuidString,
                       "ops": [["op": "ensure_net", "name": "VCC"]]] as JSONDictionary
        ] as JSONDictionary)
        XCTAssertNil(added["error"], "\(added)")
        return (target, { selection }, { shownSheets }, { layerPresets }, {
            session.unregisterLive(handle: handle)
            try? FileManager.default.removeItem(at: root)
        })
    }

    /// Each command against the document, and what it reports.
    @MainActor
    func testCommandsActOnTheLiveDocumentAndReportBack() throws {
        let live = try liveDocument()
        defer { live.cleanup() }
        let target = live.target
        let vcc = HorizontalDesignObject(kind: .net, name: "VCC")
        XCTAssertEqual(HorizontalCommandTarget.nameableObjects(in: target).map(\.name), ["VCC"])

        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.highlight([vcc]), in: target), "Highlighted VCC.")
        XCTAssertEqual(live.selection().highlightedNetIDs.count, 1)
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.clearHighlight, in: target), "Highlight cleared.")
        XCTAssertTrue(live.selection().highlightedNetIDs.isEmpty)
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.select([vcc]), in: target), "Selected VCC.")
        XCTAssertEqual(live.selection().netIDs.count, 1)
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.clearSelection, in: target), "Selection cleared.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showPanes([.board, .threeD]), in: target), "Showing the board and the 3d board.")
        XCTAssertEqual(live.selection().panes, ["board", "threeD"])
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.hidePanes([.threeD]), in: target), "Hid the 3d board.")
        XCTAssertEqual(live.selection().panes, ["board"])
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.hidePanes([.board]), in: target),
                       "That would hide every pane. Say which one to show instead.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.hidePanes([.schematic]), in: target), "The schematic is not showing.")

        // Nothing here is placed anywhere, so framing is refused with the
        // dispatch method's own message.
        XCTAssertTrue(HorizontalVoiceCommandRunner.run(.zoom([vcc], pane: nil), in: target).contains("VCC"))
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showLayers(.topPlacement), in: target), "Showing the top layer.")
        XCTAssertEqual(live.layerPresets(), [.topPlacement])
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showLayers(.all), in: target), "Showing all layers.")
        XCTAssertEqual(live.layerPresets(), [.topPlacement, .all])
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showLayers(.silkscreen), in: target), "Showing the silkscreen.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showLayers(.flipView), in: target), "Turned the board over.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.zoomBy(2, pane: nil), in: target), "Zoomed in.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.zoomBy(0.5, pane: .board), in: target), "Zoomed out.")
        XCTAssertEqual(live.layerPresets(), [.topPlacement, .all, .silkscreen, .flipView, .topView, .bottomView],
                       "the zoom steps reached the document's hook (recorded as views here)")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.nothingNamed(said: "7", family: .capacitor), in: target),
                       "There is no capacitor 7 in Untitled.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.nothingNamed(said: "flux", family: nil), in: target),
                       "Nothing in Untitled is called flux.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.ambiguous([vcc, vcc], said: "123"), in: target),
                       "123 could be VCC, VCC. Say the kind, or the whole name.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.undo, in: target), "There is nothing to undo.",
                       "a test document has no undo stack; the refusal is the channel's")
    }

    /// Sheets through the new dispatch verb: by number, by name, and relative
    /// to the one showing.
    @MainActor
    func testSheetsAreShownThroughTheChannel() throws {
        let live = try liveDocument()
        defer { live.cleanup() }
        let target = live.target
        let sheets = HorizontalCommandTarget.sheets(in: target)
        XCTAssertEqual(sheets.count, 1, "a new project has one sheet")
        let first = sheets[0]

        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showSheet(.number(1)), in: target),
                       first.name.isEmpty ? "Sheet 1." : "Sheet 1, \(first.name).")
        XCTAssertEqual(live.shownSheets(), [first.id])
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showSheet(.number(9)), in: target), "There is no sheet 9 in Untitled.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showSheet(.next), in: target), "This is the last sheet.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showSheet(.previous), in: target), "This is the first sheet.")
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showSheet(.last), in: target),
                       first.name.isEmpty ? "Sheet 1." : "Sheet 1, \(first.name).")
        if !first.name.isEmpty {
            XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showSheet(.named(first.name)), in: target), "Sheet 1, \(first.name).")
        }
        XCTAssertEqual(HorizontalVoiceCommandRunner.run(.showSheet(.named("nowhere")), in: target),
                       "There is no sheet called nowhere in Untitled.")

        // The verb itself, as an agent would call it.
        let direct = HorizontalDispatch.call([
            "jsonrpc": "2.0", "id": 2, "method": "show_sheet", "params": ["handle": target.handle, "sheet": 1] as JSONDictionary
        ] as JSONDictionary)
        XCTAssertEqual((direct["result"] as? JSONDictionary)?["id"] as? String, first.id)
        let none = HorizontalDispatch.call([
            "jsonrpc": "2.0", "id": 3, "method": "show_sheet", "params": ["handle": target.handle] as JSONDictionary
        ] as JSONDictionary)
        XCTAssertNotNil(none["error"], "a sheet has to be named")
    }

    /// The controller: a settled utterance becomes a command and a message,
    /// and a fragment too short to be a command waits for the rest.
    @MainActor
    func testTheControllerRunsWhatItHearsAndWaitsForFragments() throws {
        let live = try liveDocument()
        defer { live.cleanup() }
        let control = HorizontalVoiceControl()
        control.target = { live.target }

        control.run("highlight")
        XCTAssertNil(control.message, "a bare verb is kept for what follows")
        control.run("VCC")
        XCTAssertEqual(control.message, "“highlight VCC” — Highlighted VCC.")
        XCTAssertEqual(live.selection().highlightedNetIDs.count, 1)

        control.run("show the board")
        XCTAssertEqual(control.message, "“show the board” — Showing the board.")
        control.run("select it")
        XCTAssertEqual(control.message, "“select it” — Selected VCC.", "the last thing named is remembered across sentences")
        control.run("zoom")
        XCTAssertTrue(control.message?.contains("VCC") == true, "a bare verb means it too: \(control.message ?? "")")
        control.run("what is the weather like today")
        XCTAssertEqual(control.message, "“what is the weather like today” — Not a command I know. Try “highlight C12”, “zoom to ground”, “show the board” or “sheet 2”.")

        // A verb that settled with only a filler after it — "highlight what"
        // — and a bent verb are both halves of a command, and wait for the
        // name.
        control.run("highlight what")
        XCTAssertEqual(control.message, "“what is the weather like today” — Not a command I know. Try “highlight C12”, “zoom to ground”, “show the board” or “sheet 2”.", "nothing new said yet")
        control.run("VCC")
        XCTAssertEqual(control.message, "“highlight what VCC” — Highlighted VCC.")
        control.run("Highlight, um, what")
        control.run("VCC")
        XCTAssertEqual(control.message, "“Highlight, um, what VCC” — Highlighted VCC.")
        control.run("highlights")
        XCTAssertEqual(control.message, "“highlights” — Highlighted VCC.", "a bare verb, bent or not, still takes the last thing")

        // With nothing named yet, a bent bare verb is half a sentence too.
        let fresh = HorizontalVoiceControl()
        fresh.target = { live.target }
        fresh.run("highlights")
        XCTAssertNil(fresh.message)
        fresh.run("VCC")
        XCTAssertEqual(fresh.message, "“highlights VCC” — Highlighted VCC.")
        fresh.run("select what")
        fresh.run("show the board")
        XCTAssertEqual(fresh.message, "“show the board” — Showing the board.", "a whole command is not spoiled by the fragment before it")
    }

    /// The whole path from sound to command, spoken by `say`. Needs the
    /// on-device speech model, so it runs only when asked for.
    func testASpokenSentenceIsTranscribedAndRead() async throws {
        guard ProcessInfo.processInfo.environment["HORIZONTAL_SPEECH_TESTS"] == "1" else {
            throw XCTSkip("set HORIZONTAL_SPEECH_TESTS=1 to transcribe a synthesized sentence")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-voice-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "highlight capacitor 123"]
        try say.run()
        say.waitUntilExit()
        let heard = try await HorizontalSpeechListener.transcribe(fileAt: file, contextualStrings: parts.map(\.name), installingModel: true)
        XCTAssertFalse(heard.isEmpty)
        XCTAssertEqual(parse(heard), .highlight([object("C123")]), "heard: \(heard)")
    }
}
