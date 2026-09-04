import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The schematic-mode projections: a symbol or frame becomes a synthetic
/// sheet the schematic canvas can edit, and comes back unchanged.
final class HorizontalPoolSymbolEditingTests: XCTestCase {
    var poolURL: URL!

    override func setUpWithError() throws {
        poolURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolSymbolEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: poolURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: poolURL)
    }

    static var unitJSON: JSONDictionary { [
        "type": "unit", "uuid": "u1", "name": "Op-amp", "manufacturer": "", "version": 1,
        "pins": [
            "p1": ["primary_name": "IN+", "direction": "input", "swap_group": 0, "names": [],
                   "alt_names": ["a1": ["name": "A", "direction": "input"], "a2": ["name": "B", "direction": "input"]]],
            "p2": ["primary_name": "OUT", "direction": "output", "swap_group": 0, "names": [], "alt_names": [:]],
            "p3": ["primary_name": "VCC", "direction": "power_input", "swap_group": 0, "names": [], "alt_names": [:]],
        ],
    ] }

    static var symbolJSON: JSONDictionary { [
        "type": "symbol", "uuid": "s1", "name": "Op-amp", "unit": "u1", "can_expand": true,
        "junctions": ["j1": ["position": [0, 0]], "j2": ["position": [1_250_000, 0]], "j3": ["position": [0, 1_250_000]]],
        "lines": ["l1": ["from": "j1", "to": "j2", "width": 0, "layer": 0]],
        "arcs": ["a1": ["from": "j2", "to": "j3", "center": "j1", "width": 0, "layer": 0]],
        "polygons": ["q1": ["layer": 0, "parameter_class": "", "vertices": [
            ["type": "line", "position": [175_000, 0], "arc_center": [0, 0], "arc_reverse": false],
            ["type": "arc", "position": [175_000, 0], "arc_center": [0, 0], "arc_reverse": true],
        ]]],
        "texts": [
            "t1": ["origin": "center", "text": "$REFDES", "size": 1_500_000, "width": 0, "layer": 0,
                   "placement": ["shift": [0, 2_500_000], "angle": 0, "mirror": false]],
            "t2": ["origin": "baseline", "font": "complex", "text": "", "size": 1_500_000, "width": 0,
                   "layer": 0, "from_smash": false, "allow_upside_down": true,
                   "placement": ["shift": [0, -2_500_000], "angle": 16_384, "mirror": true]],
        ],
        "pins": [
            "p1": ["position": [-2_500_000, 0], "length": 2_500_000, "orientation": "right",
                   "name_visible": false, "pad_visible": true, "keep_horizontal": true,
                   "decoration": ["dot": true, "clock": false, "schmitt": true, "driver": "tristate"]],
            "p2": ["position": [2_500_000, 0], "length": 2_500_000, "orientation": "left"],
        ],
        "text_placements": ["90m": ["t1": ["shift": [1, 2], "angle": 16_384, "mirror": true]]],
    ] }

    private func makeContext(
        pinDisplayMode: HorizontalSymbolEditorPinDisplayMode = .primary,
        hiddenNames: Bool = false
    ) -> HorizontalSymbolEditorContext {
        HorizontalSymbolEditorContext(
            symbolID: "s1",
            unitID: "u1",
            unitJSON: HorizontalPreservedJSON(Self.unitJSON),
            poolURL: poolURL,
            pinDisplayMode: pinDisplayMode,
            showsJunctionsAndHiddenNames: hiddenNames
        )
    }

    private func normalized(_ json: JSONDictionary) throws -> String {
        try HorizontalHorizonJSONWriter.string(json)
    }

    // MARK: - Symbol

    func testSymbolProjectsToASheetAndBack() throws {
        let symbol = try HorizontalPoolSymbol(json: Self.symbolJSON)
        let unit = try HorizontalPoolUnit(json: Self.unitJSON)
        let sheet = symbol.makeSheet(context: makeContext(), unit: unit)

        XCTAssertEqual(sheet.junctions.count, 3)
        XCTAssertEqual(sheet.drawingLines.map(\.id), ["sheet/line/l1"])
        XCTAssertEqual(sheet.drawingArcs.map(\.id), ["sheet/arc/a1"])
        XCTAssertEqual(sheet.drawingPolygons.map(\.id), ["sheet/polygon/q1"])
        XCTAssertEqual(sheet.drawingPolygons.first?.polygonVertices.count, 2, "arc vertices survive")
        XCTAssertEqual(sheet.texts.count, 2, "the empty text is kept")
        XCTAssertEqual(sheet.editablePins.map(\.id), ["p1", "p2"])
        // Mirrored texts carry the sheet's angle convention (32768 − file angle).
        let mirroredText = try XCTUnwrap(sheet.texts.first { $0.id == "t2" })
        XCTAssertTrue(mirroredText.mirrored)
        XCTAssertEqual(mirroredText.angle, 32_768 - 16_384)
        XCTAssertEqual(sheet.placeableObjects.map(\.id), ["p3"], "only the unplaced unit pin is offered")
        XCTAssertEqual(sheet.grid.spacing.x, 1_250_000)

        // Pin artwork is keyed by the symbol uuid so the canvas can map it back.
        XCTAssertTrue(sheet.symbolPins.contains { $0.id == "s1/pin/p1" })
        XCTAssertTrue(sheet.symbolPinCircles.contains { $0.id.hasPrefix("s1/pin-decoration/p1") }, "p1 has a dot")
        XCTAssertTrue(sheet.symbolTexts.contains { $0.id == "s1/pin-name/p2" && $0.text == "OUT" })
        XCTAssertFalse(sheet.symbolTexts.contains { $0.id == "s1/pin-name/p1" }, "p1 hides its name")
        XCTAssertTrue(sheet.symbolTexts.contains { $0.id == "s1/pin-pad/p1" && $0.text == "$PAD" }, "pads read $PAD in the editor")

        let restored = symbol.applying(sheet: sheet)
        XCTAssertEqual(try normalized(restored.json()), try normalized(Self.symbolJSON))
    }

    func testEditingTheSheetReachesTheSymbol() throws {
        let symbol = try HorizontalPoolSymbol(json: Self.symbolJSON)
        let context = makeContext()
        var sheet = symbol.makeSheet(context: context, unit: try HorizontalPoolUnit(json: Self.unitJSON))

        // Move a pin: only its artwork shifts, nothing re-bakes.
        let before = sheet.symbolPins.count
        sheet.shiftEditablePin(id: "p2", by: HorizontalPoint(x: 1_250_000, y: 0))
        XCTAssertEqual(sheet.symbolPins.count, before)
        XCTAssertEqual(sheet.editablePin(id: "p2")?.position, HorizontalPoint(x: 3_750_000, y: 0))
        XCTAssertEqual(sheet.symbolPins.first { $0.id == "s1/pin/p2" }?.from, HorizontalPoint(x: 3_750_000, y: 0))

        // Change a decoration and re-bake: the old artwork is replaced.
        if let index = sheet.editablePinIndex(id: "p2") {
            sheet.editablePins[index].decoration.clock = true
            sheet.editablePins[index].nameVisible = false
        }
        sheet.rebakeEditablePin(id: "p2", context: context)
        XCTAssertTrue(sheet.symbolPins.contains { $0.id.hasPrefix("s1/pin-decoration/p2/clock") })
        XCTAssertFalse(sheet.symbolTexts.contains { $0.id == "s1/pin-name/p2" })
        XCTAssertEqual(sheet.symbolPins.filter { $0.id == "s1/pin/p2" }.count, 1, "no duplicate stem")

        // Place the remaining pin, draw a polygon, delete the arc.
        sheet.editablePins.append(HorizontalSymbolPin(id: "p3", position: HorizontalPoint(x: 0, y: 5_000_000), orientation: .down))
        sheet.rebakeEditablePin(id: "p3", context: context)
        sheet.drawingPolygons.append(HorizontalPolygon(
            id: "sheet/polygon/new",
            polygonVertices: [
                HorizontalPolygonVertex(position: HorizontalPoint(x: 0, y: 0)),
                HorizontalPolygonVertex(position: HorizontalPoint(x: 1_000_000, y: 0)),
                HorizontalPolygonVertex(position: HorizontalPoint(x: 0, y: 1_000_000)),
            ],
            layer: 0
        ))
        sheet.drawingArcs.removeAll()

        let edited = symbol.applying(sheet: sheet)
        XCTAssertEqual(edited.pins["p2"]?.position, HorizontalPoint(x: 3_750_000, y: 0))
        XCTAssertEqual(edited.pins["p2"]?.decoration.clock, true)
        XCTAssertEqual(edited.pins["p3"]?.orientation, .down)
        XCTAssertEqual(Set(edited.drawing.polygons.keys), ["q1", "new"], "the sheet prefix is stripped")
        XCTAssertTrue(edited.drawing.arcs.isEmpty)
        XCTAssertEqual(edited.drawing.lines["l1"]?.from, "j1")
        XCTAssertEqual(edited.drawing.lines["l1"]?.to, "j2")
        XCTAssertNil(edited.drawing.junctions["j3"], "the junction only the arc used is vacuumed")
        XCTAssertEqual(edited.name, symbol.name)
        XCTAssertEqual(edited.textPlacements, symbol.textPlacements, "untouched fields ride along")
    }

    func testHiddenNamesAndPinDisplayModes() throws {
        let symbol = try HorizontalPoolSymbol(json: Self.symbolJSON)
        let unit = try HorizontalPoolUnit(json: Self.unitJSON)

        let hidden = symbol.makeSheet(context: makeContext(hiddenNames: true), unit: unit)
        let hiddenName = try XCTUnwrap(hidden.symbolTexts.first { $0.id == "s1/pin-name-hidden/p1" })
        XCTAssertEqual(hiddenName.text, "IN+")
        XCTAssertFalse(hidden.symbolTexts.contains { $0.id == "s1/pin-name-hidden/p2" }, "visible names are not duplicated")
        XCTAssertEqual(HorizontalSchematicSheet.editorPinID(forGeometryID: "s1/pin-name-hidden/p1"), "p1")

        let alternate = symbol.makeSheet(context: makeContext(pinDisplayMode: .alternate), unit: unit)
        XCTAssertFalse(alternate.symbolTexts.contains { $0.id == "s1/pin-name/p2" }, "no alternates → no name text")
        let bothSheet = symbol.makeSheet(context: makeContext(pinDisplayMode: .both, hiddenNames: true), unit: unit)
        XCTAssertEqual(bothSheet.symbolTexts.first { $0.id == "s1/pin-name-hidden/p1" }?.text, "A · B · (IN+)")
        XCTAssertEqual(bothSheet.symbolTexts.first { $0.id == "s1/pin-name/p2" }?.text, "(OUT)")
        let altHidden = symbol.makeSheet(context: makeContext(pinDisplayMode: .alternate, hiddenNames: true), unit: unit)
        XCTAssertEqual(altHidden.symbolTexts.first { $0.id == "s1/pin-name-hidden/p1" }?.text, "A · B")
    }

    func testChangingUnitRemapsPinsByPrimaryName() throws {
        let symbol = try HorizontalPoolSymbol(json: Self.symbolJSON)
        let oldUnit = try HorizontalPoolUnit(json: Self.unitJSON)
        var newJSON = Self.unitJSON
        newJSON["uuid"] = "u2"
        newJSON["pins"] = [
            "n1": ["primary_name": "OUT", "direction": "output", "swap_group": 0, "names": [], "alt_names": [:]],
            "n2": ["primary_name": "GND", "direction": "power_input", "swap_group": 0, "names": [], "alt_names": [:]],
        ] as JSONDictionary
        let newUnit = try HorizontalPoolUnit(json: newJSON)

        let changed = symbol.changingUnit(to: newUnit, from: oldUnit)
        XCTAssertEqual(changed.unitID, "u2")
        XCTAssertEqual(Set(changed.pins.keys), ["n1"], "OUT survives under its new id, IN+ is dropped")
        XCTAssertEqual(changed.pins["n1"]?.position, symbol.pins["p2"]?.position)
        XCTAssertEqual(changed.unplacedPinObjects(unit: newUnit).map(\.label), ["GND"])
    }

    func testPinOrientationTransforms() {
        XCTAssertEqual(HorizontalPinOrientation.right.rotated(clockwise: true), .down)
        XCTAssertEqual(HorizontalPinOrientation.right.rotated(clockwise: false), .up)
        XCTAssertEqual(HorizontalPinOrientation.up.rotated(clockwise: true), .right)
        XCTAssertEqual(HorizontalPinOrientation.left.mirrored, .right)
        XCTAssertEqual(HorizontalPinOrientation.up.mirrored, .up)
    }

    // MARK: - Frame

    func testFrameProjectsWithItsBorderAndBack() throws {
        let json: JSONDictionary = [
            "type": "frame", "uuid": "f1", "name": "A4", "width": 297_000_000, "height": 210_000_000,
            "junctions": ["j1": ["position": [10_000_000, 10_000_000]], "j2": ["position": [50_000_000, 10_000_000]]],
            "lines": ["l1": ["from": "j1", "to": "j2", "width": 0, "layer": 0]],
            "arcs": [:], "polygons": [:],
            "texts": ["t1": ["origin": "center", "text": "$sheet_title", "size": 2_000_000, "width": 0, "layer": 0,
                             "placement": ["shift": [20_000_000, 5_000_000], "angle": 0, "mirror": false]]],
        ]
        let frame = try HorizontalPoolFrame(json: json)
        var sheet = frame.makeSheet()
        XCTAssertEqual(sheet.frameLines.count, 4, "the page border is drawn, not editable")
        XCTAssertTrue(sheet.frameLines.contains { $0.to == HorizontalPoint(x: 297_000_000, y: 210_000_000) })
        XCTAssertEqual(sheet.drawingLines.count, 1)
        XCTAssertEqual(sheet.texts.first?.text, "$sheet_title", "placeholders stay literal")
        XCTAssertEqual(try normalized(frame.applying(sheet: sheet).json()), try normalized(json))

        // Draw a new line between fresh points: junctions are minted for it.
        sheet.drawingLines.append(HorizontalSegment(
            id: "sheet/line/new",
            from: HorizontalPoint(x: 0, y: 0),
            to: HorizontalPoint(x: 50_000_000, y: 10_000_000),
            width: 0,
            layer: 0
        ))
        let edited = frame.applying(sheet: sheet)
        XCTAssertEqual(edited.drawing.lines.count, 2)
        XCTAssertEqual(edited.drawing.junctions.count, 3, "one new junction; the shared end reuses j2")
        XCTAssertEqual(edited.drawing.lines["new"]?.to, "j2")
        XCTAssertEqual(edited.width, frame.width)
    }
}

// MARK: - Follow-ups: text placement views, polygon vertices

extension HorizontalPoolSymbolEditingTests {
    func testTextPlacementViewsInvertExactly() {
        let placements = [
            HorizontalPlacementTransform(shift: HorizontalPoint(x: 1_250_000, y: -2_500_000), angle: 0, mirrored: false),
            HorizontalPlacementTransform(shift: HorizontalPoint(x: -3_750_000, y: 1_250_000), angle: 16_384, mirrored: true),
            HorizontalPlacementTransform(shift: HorizontalPoint(x: 0, y: 2_500_000), angle: 49_152, mirrored: false),
        ]
        for view in HorizontalSymbolTextPlacementView.all {
            for placement in placements {
                let placed = view.transform.accumulatedText(with: placement)
                let recovered = view.transform.textPlacement(undoing: placed)
                XCTAssertEqual(recovered, placement, "view \(view.key)")
            }
        }
        XCTAssertEqual(HorizontalSymbolTextPlacementView.all.map(\.key), ["0n", "90n", "180n", "270n", "0m", "90m", "180m", "270m"])
    }

    func testTextPlacementViewEditsOnlyThatViewsPlacements() throws {
        var json = Self.symbolJSON
        json["text_placements"] = [:] as JSONDictionary
        let symbol = try HorizontalPoolSymbol(json: json)
        let unit = try HorizontalPoolUnit(json: Self.unitJSON)
        let view = HorizontalSymbolTextPlacementView(angleDegrees: 90, mirrored: true)
        var context = HorizontalSymbolEditorContext(symbolID: "s1", unitID: "u1", unitJSON: HorizontalPreservedJSON(Self.unitJSON), poolURL: poolURL)
        context.view = view

        var sheet = symbol.makeSheet(context: context, unit: unit)
        XCTAssertTrue(sheet.placeableObjects.isEmpty, "no pin placing in a view")
        // Geometry is shown as placed in the view: the line from (0,0)→(1.25,0)
        // mirrored first (Horizon's order) then rotated 90° lands on (0,−1.25).
        let line = try XCTUnwrap(sheet.drawingLines.first)
        XCTAssertEqual(Int(line.to.x.rounded()), 0)
        XCTAssertEqual(Int(line.to.y.rounded()), -1_250_000)
        XCTAssertTrue(sheet.symbolPins.contains { $0.id == "s1/pin/p1" }, "pins bake in the view too")

        // Drag the refdes text somewhere in the view.
        guard let textIndex = sheet.texts.firstIndex(where: { $0.id == "t1" }) else {
            return XCTFail("refdes text missing")
        }
        sheet.texts[textIndex].position = HorizontalPoint(x: 5_000_000, y: 1_250_000)
        let edited = symbol.applying(sheet: sheet, view: view)
        XCTAssertEqual(edited.drawing, symbol.drawing, "the drawing itself is untouched")
        XCTAssertEqual(edited.pins, symbol.pins)
        let viewPlacements = try XCTUnwrap(edited.textPlacements["90m"])
        XCTAssertEqual(Set(viewPlacements.keys), ["t1", "t2"], "every text of the view is recorded")
        XCTAssertEqual(edited.requiredVersion, 1)
        // Re-projecting the view places the text where it was dragged.
        let again = edited.makeSheet(context: context, unit: unit)
        XCTAssertEqual(again.texts.first { $0.id == "t1" }?.position, HorizontalPoint(x: 5_000_000, y: 1_250_000))
        // Other views are unaffected: the plain editor shows the file placement.
        context.view = nil
        let plain = edited.makeSheet(context: context, unit: unit)
        XCTAssertEqual(plain.texts.first { $0.id == "t1" }?.position, HorizontalPoint(x: 0, y: 2_500_000))
        // Clearing removes the view.
        XCTAssertNil(edited.clearingTextPlacements(for: view).textPlacements["90m"])
    }

    func testDeletingPolygonVerticesMirrorsTheBoard() throws {
        let symbol = try HorizontalPoolSymbol(json: Self.symbolJSON)
        var sheet = symbol.makeSheet(context: HorizontalSymbolEditorContext(symbolID: "s1", unitID: "u1", unitJSON: nil, poolURL: poolURL), unit: nil)
        sheet.drawingPolygons.append(HorizontalPolygon(
            id: "sheet/polygon/tri",
            polygonVertices: [
                HorizontalPolygonVertex(position: HorizontalPoint(x: 0, y: 0)),
                HorizontalPolygonVertex(type: .arc, position: HorizontalPoint(x: 1_000_000, y: 0), arcCenter: HorizontalPoint(x: 500_000, y: 0)),
                HorizontalPolygonVertex(position: HorizontalPoint(x: 0, y: 1_000_000)),
                HorizontalPolygonVertex(position: HorizontalPoint(x: -1_000_000, y: 1_000_000)),
            ],
            layer: 0
        ))
        // An arc centre becomes a straight edge.
        XCTAssertTrue(sheet.deleteDrawingPolygonVertices(HorizontalSelectableRef(id: "sheet/polygon/tri", type: .polygonArcCenter, vertex: 1)))
        XCTAssertEqual(sheet.drawingPolygons.last?.polygonVertices[1].type, .line)
        // An edge takes both its vertices.
        XCTAssertTrue(sheet.deleteDrawingPolygonVertices(HorizontalSelectableRef(id: "sheet/polygon/tri", type: .polygonEdge, vertex: 0)))
        XCTAssertEqual(sheet.drawingPolygons.last?.polygonVertices.count, 2)
        // One vertex more and the polygon is gone.
        XCTAssertTrue(sheet.deleteDrawingPolygonVertices(HorizontalSelectableRef(id: "sheet/polygon/tri", type: .polygonVertex, vertex: 0)))
        XCTAssertFalse(sheet.drawingPolygons.contains { $0.id == "sheet/polygon/tri" })
        XCTAssertFalse(sheet.deleteDrawingPolygonVertices(HorizontalSelectableRef(id: "missing", type: .polygonVertex, vertex: 0)))
    }
}
