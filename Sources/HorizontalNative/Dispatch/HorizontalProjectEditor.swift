import Foundation
import HorizontalProjectIO

/// The edit vocabulary: operations as data, applied to the project files the
/// way Horizon lays them out. Every headless front end submits these, and the
/// app's live channel will take the same ones onto its undo stack.
enum HorizontalEditOperationKind: String, CaseIterable {
    case ensureComponent = "ensure_component"
    case removeComponent = "remove_component"
    case setValue = "set_value"
    case setRefdes = "set_refdes"
    case setPart = "set_part"
    case setNoPopulate = "set_no_populate"
    case setGroupTag = "set_group_tag"
    case ensureNet = "ensure_net"
    case addBus = "add_bus"
    case removeBus = "remove_bus"
    case addBusMember = "add_bus_member"
    case placeBusLabel = "place_bus_label"
    case placeBusRipper = "place_bus_ripper"
    case addNetTie = "add_net_tie"
    case removeNetTie = "remove_net_tie"
    case placeNetTie = "place_net_tie"
    case addNetClass = "add_net_class"
    case renameNetClass = "rename_net_class"
    case renameNet = "rename_net"
    case setNetClass = "set_net_class"
    case retireNet = "retire_net"
    case connect = "connect"
    case disconnect = "disconnect"
    case placeSymbol = "place_symbol"
    case removeSymbol = "remove_symbol"
    case drawNetLine = "draw_net_line"
    case placeJunction = "place_junction"
    case setNetLineEndpoint = "set_net_line_endpoint"
    case removeNetLine = "remove_net_line"
    case removeJunction = "remove_junction"
    case pruneSheet = "prune_sheet"
    case terminatePin = "terminate_pin"
    case setSymbolDisplay = "set_symbol_display"
    case setNoConnect = "set_no_connect"
    case remapPart = "remap_part"
    case placeText = "place_text"
    case removeText = "remove_text"
    case placePowerSymbol = "place_power_symbol"
    case removePowerSymbol = "remove_power_symbol"
    case placeNetLabel = "place_net_label"
    case removeNetLabel = "remove_net_label"
    case addBlockInstance = "add_block_instance"
    case removeBlockInstance = "remove_block_instance"
    case connectBlockPort = "connect_block_port"
    case placeBlockSymbol = "place_block_symbol"
    case removeBlockSymbol = "remove_block_symbol"
    case setStackup = "set_stackup"
    case addRule = "add_rule"
    case setRule = "set_rule"
    case removeRule = "remove_rule"
    case addSheet = "add_sheet"
    case renameSheet = "rename_sheet"
    case removeSheet = "remove_sheet"
    case placeTrack = "place_track"
    case removeTrack = "remove_track"
    case setTrackWidth = "set_track_width"
    case placeVia = "place_via"
    case removeVia = "remove_via"
    case placePolygon = "place_polygon"
    case removePolygon = "remove_polygon"
    case placePlane = "place_plane"
    case removePlane = "remove_plane"
    case placeHole = "place_hole"
    case removeHole = "remove_hole"
    case placeKeepout = "place_keepout"
    case removeKeepout = "remove_keepout"
    case placeBoardText = "place_board_text"
    case removeBoardText = "remove_board_text"
    case placeDimension = "place_dimension"
    case removeDimension = "remove_dimension"
    case setSheetIndex = "set_sheet_index"
    case placeComponent = "place_component"
    case removePlacement = "remove_placement"
    case copyGroupLayout = "copy_group_layout"

    /// A digest of every op and its parameter names, in a form the Python
    /// client computes from its own schema the same way: lines of
    /// "op:param,param" sorted, joined by newlines, SHA-256, first 16 hex digits.
    static var vocabularyDigest: String {
        let lines = allCases.map { "\($0.rawValue):\($0.params.keys.sorted().joined(separator: ","))" }.sorted()
        return String(HorizontalProjectTransaction.digest(Data(lines.joined(separator: "\n").utf8)).prefix(16))
    }

    var summary: String {
        switch self {
        case .ensureComponent: "Create a block component if it does not exist; returns its id."
        case .removeComponent: "Remove a component, its symbols, its board package, and the copper attached to it."
        case .setValue: "Set a component's value."
        case .setRefdes: "Set a component's reference designator."
        case .setPart: "Assign a pool part (and its entity) to a component; null clears the part."
        case .setNoPopulate: "Mark a component do-not-populate or not."
        case .setGroupTag: "Set the group and tag names Horizon uses to copy placement between identical sub-circuits."
        case .ensureNet: "Create a net if no net has that id or name; returns its id."
        case .addBus: "Create a bus — a named bundle the nets in it travel as one line on a sheet."
        case .removeBus: "Remove a bus, its members, and the labels and rippers drawn for it."
        case .addBusMember: "Put a net in a bus under a member name."
        case .placeBusLabel: "Label a bus on a sheet, the way a net label names a net."
        case .placeBusRipper: "Take one member off a bus at a point, so it can be wired on its own."
        case .addNetTie: "Tie two nets together — joined on the board, kept apart in the schematic, which is what a tie is for."
        case .removeNetTie: "Remove a net tie and the symbols drawn for it."
        case .placeNetTie: "Draw a net tie on a sheet, between a point on each of its two nets."
        case .addNetClass: "Create a net class. Its electrical parameters live in the board rules; board_rules shows them."
        case .renameNetClass: "Rename a net class."
        case .renameNet: "Rename a net."
        case .setNetClass: "Put a net in a net class, by name or id."
        case .retireNet: "Remove a net, every connection to it, and the labels, power symbols, wires and junctions drawn for it. Board copper on it is reported, or removed with remove_routing."
        case .connect: "Connect a component pin to a net."
        case .disconnect: "Remove a pin's connection."
        case .placeSymbol: "Draw a component's gate on a schematic sheet, or move it if it is already drawn. A component connected without this is in the netlist but on no sheet."
        case .setSymbolDisplay: "Change how a drawn symbol shows its pins: which pin names (pin_display_mode) and whether a multi-pad pin lists every pad number (display_all_pads)."
        case .removeSymbol: "Take a component's gate off its sheet, with the net lines that ended on it. The component and its connections stay."
        case .drawNetLine: "Draw a wire between pins or junctions on one logical net. Does not change block connectivity. A junction with no net yet takes the wire's."
        case .placeJunction: "Create a schematic junction on a net, reusing a compatible or net-less junction at the same point."
        case .setNetLineEndpoint: "Retarget one end of an existing wire, keeping its id and logical net."
        case .removeNetLine: "Remove a wire from its sheet, and any junction at its ends that it leaves holding nothing."
        case .removeJunction: "Remove a junction with the wires ending on it and the labels and power symbols sitting on it — net-less junctions included."
        case .pruneSheet: "Clear orphaned drawing from a sheet: wires with a dangling end, wiring islands that carry no net and reach no pin, labels on no net, and junctions nothing uses. unanchored and stubs widen it to wiring that names a net but reaches no pin, and wire ends to nowhere."
        case .terminatePin: "Draw a short wire straight out from a symbol pin and end it in a net label or power symbol facing away from the pin. Connects the pin to the net first when it is on none."
        case .setNoConnect: "Mark component pins as deliberately not connected, or clear the mark. A pin on a net is refused unless disconnect is passed."
        case .remapPart: "Replace a component's part, preserving connections, symbols and wires atomically. Pins are matched by name unless an explicit gate/pin identity map is given."
        case .placeText: "Write a text on a schematic sheet, or change one that is already there. Free text only: a symbol's own texts belong to the symbol."
        case .removeText: "Remove a text from a schematic sheet."
        case .placePowerSymbol: "Draw a power symbol on a sheet: the ground or supply marker that says a point is on that net. Marks the net as a power net, since that is what one means."
        case .removePowerSymbol: "Remove a power symbol from its sheet."
        case .placeNetLabel: "Label a net on a sheet. A label is how a net is named on the page, and how one net spans several sheets."
        case .removeNetLabel: "Remove a net label from its sheet."
        case .addBlockInstance: "Use another block inside this one: one instance of it, with its own reference designator."
        case .removeBlockInstance: "Remove a block instance and every symbol drawn for it."
        case .connectBlockPort: "Connect a block instance's port to a net in the block that uses it. Ports are how a sub-block reaches the design around it."
        case .placeBlockSymbol: "Draw a block instance on a sheet, using the symbol that block defines for itself."
        case .removeBlockSymbol: "Take a block instance's symbol off its sheet. The instance stays."
        case .addRule: "Add a board design rule of a kind, with the defaults the app's own rules editor would give it."
        case .setRule: "Change fields of a board design rule. The board is refused if the change makes the rules invalid."
        case .removeRule: "Remove a board design rule."
        case .setStackup: "Set how many inner copper layers the board has, and the copper and dielectric thicknesses."
        case .addSheet: "Add a schematic sheet, with the drawing frame the other sheets use. An index already taken inserts the sheet there and moves the later ones down."
        case .renameSheet: "Rename a schematic sheet."
        case .removeSheet: "Remove a schematic sheet. A sheet with anything drawn on it is refused unless force is passed, which clears it — symbols included, though their components stay in the block."
        case .placeTrack: "Route one straight copper segment on a layer between two points, pads or junctions. Manual routing: it draws what it is told and does not find a path."
        case .removeTrack: "Remove a copper segment, and any junction it leaves holding nothing."
        case .setTrackWidth: "Set a copper segment's width."
        case .placeVia: "Put a via at a point, on a net, joining the layers its padstack spans."
        case .removeVia: "Remove a via, and the junction it sat on when nothing else needs it."
        case .placePolygon: "Draw a closed polygon on a board layer. Layer 100 is the board outline, which is what gives a board its shape."
        case .removePolygon: "Remove a board polygon. A polygon a plane pours into belongs to that plane."
        case .placePlane: "Define a copper pour: a polygon on a copper layer, filled with one net. Defining it does not fill it — pour_planes does that."
        case .removePlane: "Remove a plane and the polygon it pours into."
        case .placeHole: "Put a hole through the board — a mounting hole, or a plated one on a net."
        case .removeHole: "Remove a board hole."
        case .placeKeepout: "Mark an area where copper may not go, on one layer or all of them."
        case .removeKeepout: "Remove a keepout and the polygon bounding it."
        case .placeBoardText: "Write a text on a board layer — silkscreen, assembly, fabrication notes — or change one that is there."
        case .removeBoardText: "Remove a board text. A text a package carries belongs to that package."
        case .placeDimension: "Measure between two points on the board, the way the dimension tool does."
        case .removeDimension: "Remove a dimension."
        case .setSheetIndex: "Move a schematic sheet to a page number, shifting the sheets between; swap exchanges it with the one there instead."
        case .placeComponent: "Place a component's package on the board, or move it if it is placed."
        case .removePlacement: "Take a component's package off the board, keeping its copper as junctions."
        case .copyGroupLayout: "Copy the placement (and by default the routing) of one group's packages onto another group whose components carry the same tags."
        }
    }

    var params: [String: String] {
        let component = "Reference designator or component id."
        switch self {
        case .ensureComponent:
            return ["id": "Component id to use (optional).", "refdes": "Reference designator (optional; defaults to the entity's prefix plus ?).", "part": "Pool part id.", "entity": "Pool entity id (when there is no part).", "value": "Value (optional).", "group": "Group name (optional).", "tag": "Tag name (optional)."]
        case .removeComponent:
            return ["component": component,
                    "texts_within_mm": "Also remove free text this close to the component's symbols when they are the nearest symbol to it — the notes that described the part (optional)."]
        case .removePlacement:
            return ["component": component]
        case .setValue:
            return ["component": component, "value": "New value."]
        case .setRefdes:
            return ["component": component, "refdes": "New reference designator."]
        case .setPart:
            return ["component": component, "part": "Pool part id, or null."]
        case .setNoPopulate:
            return ["component": component, "no_populate": "true or false."]
        case .setGroupTag:
            return ["component": component, "group": "Group name, or null.", "tag": "Tag name, or null."]
        case .ensureNet:
            return ["id": "Net id to use (optional).", "name": "Net name.", "net_class": "Net class name or id (optional).", "is_power": "Power net (optional)."]
        case .addBus:
            return ["name": "Bus name.", "id": "Bus id to use (optional)."]
        case .removeBus:
            return ["bus": "Bus name or id."]
        case .addBusMember:
            return ["bus": "Bus name or id.", "name": "Member name within the bus.", "net": "Net name or id it carries.",
                    "id": "Member id to use (optional)."]
        case .placeBusLabel:
            return ["bus": "Bus name or id.", "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "orientation": "right, left, up or down (optional; default right).",
                    "size_mm": "Cap height (optional; default 1.5)."]
        case .placeBusRipper:
            return ["bus": "Bus name or id.", "member": "Member name or id to take off.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "orientation": "up, down, left or right (optional; default up)."]
        case .addNetTie:
            return ["primary": "The net kept as the primary one.", "secondary": "The net tied to it.",
                    "id": "Net tie id to use (optional)."]
        case .removeNetTie:
            return ["net_tie": "Net tie id."]
        case .placeNetTie:
            return ["net_tie": "Net tie id, from list_net_ties.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "from": "{\"x_mm\", \"y_mm\"} on the primary net.", "to": "{\"x_mm\", \"y_mm\"} on the secondary."]
        case .addNetClass:
            return ["name": "Net class name.", "id": "Net class id to use (optional)."]
        case .renameNetClass:
            return ["net_class": "Net class name or id.", "name": "New name."]
        case .renameNet:
            return ["net": "Net name or id.", "name": "New name."]
        case .setNetClass:
            return ["net": "Net name or id.", "net_class": "Net class name or id."]
        case .retireNet:
            return ["net": "Net name or id.",
                    "remove_routing": "Also remove the board tracks, vias and planes on the net (default false: they are counted in the result and left alone)."]
        case .connect:
            return ["component": component, "pin": "Pin name or uuid. A name is matched whole first, so one containing \"/\" works; otherwise gate/pin, by name or id.",
                    "gate": "Gate name, suffix or id, when the pin name is on several gates (optional).",
                    "net": "Net name or id.", "create_net": "Create the net when it does not exist (default false)."]
        case .disconnect:
            return ["component": component, "pin": "Pin as for connect.", "gate": "Gate, as for connect (optional)."]
        case .placeSymbol:
            return ["component": component, "gate": "Gate name, suffix or id; optional when the entity has one gate.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "symbol": "Pool symbol uuid to draw the gate with (optional; default the one symbol in the project pool for its unit).",
                    "x_mm": "X position.", "y_mm": "Y position.", "angle_deg": "Rotation (optional, default 0 or unchanged).",
                    "mirror": "Mirror the symbol (optional).",
                    "id": "Symbol instance UUID to use for a gate drawn for the first time (optional), so later ops in the same batch can name it.",
                    "pin_display_mode": "selected_only, custom_only, both or all (optional; default selected_only for a new symbol).",
                    "display_all_pads": "List every pad number on a pin that has several (optional; Horizon's default is true)."]
        case .setSymbolDisplay:
            return ["component": component, "gate": "Gate name, suffix or id; omitted, every drawn gate of the component.",
                    "symbol_instance": "One symbol instance id instead of component and gate (optional).",
                    "pin_display_mode": "selected_only, custom_only, both or all (optional).",
                    "display_all_pads": "List every pad number on a multi-pad pin (optional)."]
        case .removeSymbol:
            return ["component": component, "gate": "Gate name, suffix or id; optional when the entity has one gate.",
                    "sheet": "Sheet index, name or uuid (optional; default every sheet).",
                    "texts_within_mm": "Also remove free text this close to the removed symbols when they are the nearest symbol to it (optional)."]
        case .drawNetLine:
            return ["component": component, "pin": "Pin as for connect.", "gate": "The pin's gate, as for connect (optional).",
                    "to_component": "The other end's component.",
                    "to_pin": "The other end's pin.", "to_gate": "The other pin's gate (optional).", "sheet": "Sheet index, name or uuid (optional).",
                    "id": "Optional wire UUID, retained by dry-run normalization.",
                    "from": "{kind: pin, symbol, pin} — pin a uuid or a name — or {kind: pin, component, gate?, pin} to find the symbol, or {kind: junction, junction}; use from/to OR the legacy component/pin fields. A junction with no net takes the other end's.",
                    "to": "The other typed endpoint, on the same sheet and net."]
        case .placeJunction:
            return ["id": "Optional junction UUID.", "sheet": "Sheet index, name or uuid (optional).", "net": "Net name or id.", "x_mm": "X position.", "y_mm": "Y position."]
        case .setNetLineEndpoint:
            return ["line": "Wire id from list_net_lines.", "end": "from or to.", "endpoint": "An endpoint as for draw_net_line.", "sheet": "Optional sheet selector."]
        case .removeNetLine:
            return ["line": "Wire id from list_net_lines.", "sheet": "Sheet index, name or uuid (optional)."]
        case .removeJunction:
            return ["junction": "Junction id from list_junctions; one with no net is fine.", "sheet": "Sheet index, name or uuid (optional).",
                    "cascade": "Also remove the wires ending on it and the labels and power symbols on it (default true; false refuses when anything uses it)."]
        case .pruneSheet:
            return ["sheet": "Sheet index, name or uuid (optional; default every sheet).",
                    "unanchored": "Also remove wiring that reaches no pin, port or bus ripper even when a label or power symbol gives it a net — a GND symbol on a stub to nowhere — with its marks (default false).",
                    "stubs": "Also remove dead-end runs: wire that stops at a junction nothing else uses, back to where it branches. These are the stubs find_dangling lists, every wire and junction of each (default false)."]
        case .terminatePin:
            return ["component": component, "pin": "Pin as for connect.", "gate": "The pin's gate, as for connect (optional).",
                    "net": "Net name or id to end the pin on. Optional when the pin is already on a net; created when create_net is passed.",
                    "create_net": "Create the net when it does not exist (default false).",
                    "kind": "label or power (optional; default power for a power net, label otherwise).",
                    "length_mm": "How far out from the pin the wire runs (optional; default 2.54).",
                    "size_mm": "Label cap height (optional; default 1.5).",
                    "style": "Power symbol style, as for place_power_symbol (optional)."]
        case .setNoConnect:
            return ["component": component, "pin": "One pin, as for connect.", "pins": "Several pins, as for connect.",
                    "gate": "Gate, as for connect (optional).",
                    "no_connect": "true marks them not connected (default); false clears the mark.",
                    "disconnect": "Take a pin off its net to mark it (default false: a connected pin is refused)."]
        case .remapPart:
            return ["component": component, "part": "Target imported pool part id.",
                    "pin_map": "Optional object mapping old gateUUID/pinUUID to new gateUUID/pinUUID. Pins it leaves out are matched by gate and pin name; every connected or drawn pin has to map one way or the other.",
                    "symbols": "Optional object mapping target gate UUIDs to symbol UUIDs.",
                    "pad_map": "Optional old pad UUID to target pad UUID map for ambiguous physical pin mappings."]
        case .placeText:
            return ["text": "The text to write. Optional when changing an existing text's placement only.",
                    "id": "Text id to change (optional; a new text otherwise). list_texts returns them.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "angle_deg": "Rotation (optional, default 0 or unchanged).", "mirror": "Mirror the text (optional).",
                    "size_mm": "Cap height (optional; default 1.5).", "width_mm": "Stroke width (optional; default 0, which is Horizon's automatic width).",
                    "origin": "baseline, center or bottom (optional; default center).",
                    "font": "simplex, complex, complex_italic, complex_small, complex_small_italic, duplex, triplex or triplex_italic (optional; default simplex)."]
        case .removeText:
            return ["id": "Text id, from list_texts.", "sheet": "Sheet index, name or uuid (optional; default every sheet)."]
        case .placePowerSymbol:
            return ["net": "Net name or id.", "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "orientation": "up, down, left or right (optional; default up).",
                    "mirror": "Mirror the symbol (optional).",
                    "style": "gnd, dot, antenna or earth (optional). The style belongs to the net, so this sets it for every symbol on that net."]
        case .removePowerSymbol:
            return ["id": "Power symbol id, from list_power_symbols."]
        case .placeNetLabel:
            return ["net": "Net name or id.", "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "orientation": "right, left, up or down (optional; default right).",
                    "size_mm": "Cap height (optional; default 1.5).",
                    "offsheet_refs": "Show the other sheets this net appears on (optional; default true)."]
        case .removeNetLabel:
            return ["id": "Net label id, from list_net_labels."]
        case .addBlockInstance:
            return ["block": "The block to use, by uuid or name.", "refdes": "Reference designator for this use of it (optional).",
                    "id": "Instance id to use (optional)."]
        case .removeBlockInstance:
            return ["instance": "Block instance id or refdes."]
        case .connectBlockPort:
            return ["instance": "Block instance id or refdes.", "port": "Port uuid on the used block, or the net name it carries there.",
                    "net": "Net name or id in this block.", "create_net": "Create the net when it does not exist (default false)."]
        case .placeBlockSymbol:
            return ["instance": "Block instance id or refdes.", "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "angle_deg": "Rotation (optional).", "mirror": "Mirror the symbol (optional)."]
        case .removeBlockSymbol:
            return ["instance": "Block instance id or refdes.", "sheet": "Sheet index, name or uuid (optional; default every sheet)."]
        case .addRule:
            return ["kind": "Rule kind, e.g. clearance_copper or track_width. board_rules lists the kinds.",
                    "id": "Rule id to use, for a kind that holds several (optional)."]
        case .setRule:
            return ["kind": "Rule kind.", "id": "Rule id, for a kind that holds several. board_rules returns them.",
                    "fields": "Object of fields to merge into the rule. board_rules shows what a rule of that kind holds."]
        case .removeRule:
            return ["kind": "Rule kind.", "id": "Rule id, for a kind that holds several."]
        case .setStackup:
            return ["inner_layers": "How many inner copper layers (0 to 30).",
                    "copper_mm": "Copper thickness per layer (optional; default 0.035).",
                    "substrate_mm": "Dielectric thickness below each layer (optional; default 1.6 shared across the cores)."]
        case .addSheet:
            return ["name": "Sheet name.", "index": "Page number (optional; default after the last sheet). A page already taken moves down to make room.",
                    "frame": "Pool frame uuid for the title block, or \"none\" (optional; default the frame the last sheet uses)."]
        case .renameSheet:
            return ["sheet": "Sheet index, name or uuid.", "name": "New name."]
        case .removeSheet:
            return ["sheet": "Sheet index, name or uuid.",
                    "force": "Remove it even when things are drawn on it (default false). Components whose symbols were there stay in the block, unplaced."]
        case .placePolygon:
            return ["layer": "Board layer number. 100 is the outline; board_info lists the rest.",
                    "vertices": "Three or more {\"x_mm\", \"y_mm\"} points, in order. The shape closes itself."]
        case .removePolygon:
            return ["polygon": "Polygon id, from list_polygons."]
        case .placePlane:
            return ["net": "Net name or id the pour carries.", "layer": "Copper layer number.",
                    "vertices": "Three or more {\"x_mm\", \"y_mm\"} points bounding the pour.",
                    "priority": "Lower pours first where planes overlap (optional; default 0)."]
        case .removePlane:
            return ["plane": "Plane id, from list_planes."]
        case .placeHole:
            return ["x_mm": "X position.", "y_mm": "Y position.",
                    "padstack": "Pool padstack uuid giving the hole its shape and size. search_pool finds one, kind padstack.",
                    "net": "Net for a plated hole (optional; a mounting hole has none).",
                    "angle_deg": "Rotation, which matters for a slot (optional)."]
        case .removeHole:
            return ["hole": "Hole id, from list_holes."]
        case .placeKeepout:
            return ["vertices": "Three or more {\"x_mm\", \"y_mm\"} points bounding the area.",
                    "layer": "Copper layer number (optional; omit for every copper layer).",
                    "keepout_class": "Horizon's keepout class name, which its rules match on (optional).",
                    "exposed_copper_only": "Only exposed copper is kept out (optional)."]
        case .removeKeepout:
            return ["keepout": "Keepout id, from list_keepouts."]
        case .placeBoardText:
            return ["text": "The text to write. Optional when changing placement only.",
                    "id": "Board text id to change (optional; a new text otherwise). list_board_texts returns them.",
                    "layer": "Board layer number. board_info lists them; 20 is top silkscreen.",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "angle_deg": "Rotation (optional).", "mirror": "Mirror the text (optional).",
                    "size_mm": "Cap height (optional; default 1.5).", "width_mm": "Stroke width (optional; default 0, Horizon's automatic width).",
                    "origin": "baseline, center or bottom (optional; default center).",
                    "font": "simplex, complex, complex_italic, complex_small, complex_small_italic, duplex, triplex or triplex_italic (optional)."]
        case .removeBoardText:
            return ["id": "Board text id, from list_board_texts."]
        case .placeDimension:
            return ["from": "{\"x_mm\", \"y_mm\"} of the first point.", "to": "{\"x_mm\", \"y_mm\"} of the second.",
                    "mode": "distance, horizontal or vertical (optional; default distance).",
                    "label_distance_mm": "How far the label sits off the line (optional; default 1).",
                    "size_mm": "Label cap height (optional; default 1.5)."]
        case .removeDimension:
            return ["dimension": "Dimension id, from list_dimensions."]
        case .setSheetIndex:
            return ["sheet": "Sheet index, name or uuid.", "index": "The page number to give it.",
                    "swap": "Exchange page numbers with the sheet there rather than moving the sheets between (default false)."]
        case .placeTrack:
            let endpoint = "One of {\"component\", \"pad\"}, {\"junction\"} or {\"x_mm\", \"y_mm\"}. A point becomes a junction."
            return ["from": endpoint, "to": endpoint, "layer": "Copper layer number; 0 is the top. board_info lists them.",
                    "width_mm": "Track width. Optional only when the board states a track_width rule for the net's class on that layer.",
                    "arc_center": "{\"x_mm\", \"y_mm\"} to curve the segment around that point instead of running straight (optional).",
                    "net": "Net name or id (optional; taken from the ends when they name one)."]
        case .removeTrack:
            return ["track": "Track id, from list_tracks."]
        case .setTrackWidth:
            return ["track": "Track id, from list_tracks.", "width_mm": "New width."]
        case .placeVia:
            return ["x_mm": "X position.", "y_mm": "Y position.", "net": "Net name or id the via carries.",
                    "padstack": "Pool padstack uuid (optional; defaults to what the board's other vias use)."]
        case .removeVia:
            return ["via": "Via id, from list_vias."]
        case .placeComponent:
            return ["component": component, "x_mm": "X position.", "y_mm": "Y position.", "angle_deg": "Rotation (optional, default 0 or unchanged).", "bottom": "Place on the bottom side (optional)."]
        case .copyGroupLayout:
            return [
                "source": "Group name or id whose layout to copy.",
                "target": "Group name or id to lay out.",
                "x_mm": "Where the target's anchor member goes (optional; default: where it already is, else beside the source).",
                "y_mm": "Y of the anchor (optional).",
                "angle_deg": "Rotation of the whole copy (optional; default: the anchor's current rotation, else the source's).",
                "include_routing": "Also copy the tracks and vias inside the source group (default true)."
            ]
        }
    }
}

struct HorizontalEditOperation {
    var kind: HorizontalEditOperationKind
    var params: JSONDictionary

    init(json: JSONDictionary) throws {
        guard let name = json.string("op") else {
            throw HorizontalDispatchError.invalidParams("Every operation needs an \"op\".")
        }
        guard let kind = HorizontalEditOperationKind(rawValue: name) else {
            throw HorizontalDispatchError.invalidParams("Unknown op \(name). Known: \(HorizontalEditOperationKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        self.kind = kind
        let unknown = Set(json.keys).subtracting(Set(kind.params.keys).union(["op"]))
        guard unknown.isEmpty else { throw HorizontalDispatchError.invalidParams("Unknown \(name) fields: \(unknown.sorted().joined(separator: ", ")).") }
        for (key, value) in json where key != "op" {
            if key == "mode" {
                guard let mode = value as? String, ["distance", "horizontal", "vertical"].contains(mode) else {
                    throw HorizontalDispatchError.invalidParams("mode must be distance, horizontal or vertical.")
                }
            } else if key == "vertices" {
                guard let vertices = value as? [Any], vertices.count >= 3, vertices.allSatisfy({ $0 is JSONDictionary }) else {
                    throw HorizontalDispatchError.invalidParams("vertices must be three or more {\"x_mm\", \"y_mm\"} points.")
                }
            } else if key == "pins" {
                guard let pins = value as? [Any], !pins.isEmpty, pins.allSatisfy({ $0 is String }) else {
                    throw HorizontalDispatchError.invalidParams("pins must be a non-empty array of pin names or ids.")
                }
            } else if ["layer", "index", "priority", "inner_layers"].contains(key) {
                try HorizontalDispatchValidation.number(value, key: key, integer: true)
            } else if ["fields", "pin_map", "symbols", "pad_map"].contains(key) {
                guard value is JSONDictionary else {
                    throw HorizontalDispatchError.invalidParams("\(key) must be an object.")
                }
            } else if ["from", "to", "arc_center", "endpoint"].contains(key) {
                // A track endpoint and an arc centre are objects; everything
                // else here is scalar.
                guard let endpoint = value as? JSONDictionary, !endpoint.isEmpty else {
                    throw HorizontalDispatchError.invalidParams("\(key) must be an object.")
                }
            } else if ["x_mm", "y_mm", "angle_deg", "size_mm", "width_mm", "copper_mm", "substrate_mm",
                       "label_distance_mm", "length_mm", "texts_within_mm"].contains(key) {
                try HorizontalDispatchValidation.number(value, key: key)
            } else if ["no_populate", "is_power", "create_net", "bottom", "include_routing", "mirror", "offsheet_refs", "exposed_copper_only",
                       "force", "cascade", "swap", "remove_routing", "display_all_pads", "no_connect", "disconnect",
                       "unanchored", "stubs"].contains(key) {
                try HorizontalDispatchValidation.boolean(value, key: key)
            } else if value is NSNull, ["part", "group", "tag"].contains(key) {
                continue
            } else if key == "sheet" {
                // A sheet is named by its page number as well as by name or uuid.
                guard value is String || value is NSNumber else {
                    throw HorizontalDispatchError.invalidParams("sheet must be a sheet index, name or uuid.")
                }
                if !(value is String) { try HorizontalDispatchValidation.number(value, key: key, integer: true) }
            } else if !(value is String) { throw HorizontalDispatchError.invalidParams("\(key) must be a string.") }
        }
        params = json
    }
}

/// Where the editor reads project files from and writes them to: the disk
/// for headless use, the open document's archive for the live channel.
protocol HorizontalProjectFileStore {
    func read(_ url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
}

struct HorizontalDiskFileStore: HorizontalProjectFileStore {
    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}

/// The document's archive: file URLs map to archive paths through the
/// manifest `completeProject` recorded, or relative to the project's base
/// for a `.horizontal` package.
final class HorizontalArchiveFileStore: HorizontalProjectFileStore {
    private(set) var archive: HorizontalProjectArchive
    private let baseURL: URL

    init(archive: HorizontalProjectArchive, baseURL: URL) {
        self.archive = archive
        self.baseURL = baseURL
    }

    func relativePath(for url: URL) -> String? {
        // Resolve archive-relative paths before filesystem-dependent URL
        // canonicalization, including files that exist only in the archive.
        let prefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        if url.path.hasPrefix(prefix) {
            let relative = String(url.path.dropFirst(prefix.count))
            guard !relative.split(separator: "/").contains("..") else { return nil }
            return relative
        }
        if let path = archive.manifest?.relativePath(for: url) {
            return path
        }
        let base = baseURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(base + "/") else {
            return nil
        }
        return String(path.dropFirst(base.count + 1))
    }

    func read(_ url: URL) throws -> Data? {
        guard let path = relativePath(for: url) else {
            return nil
        }
        return archive.regularFileData(relativePath: path)
    }

    func write(_ data: Data, to url: URL) throws {
        guard let path = relativePath(for: url) else {
            throw HorizontalDispatchError.failed("Could not map \(url.path) into the document archive rooted at \(baseURL.path).")
        }
        try archive.replaceRegularFileData(relativePath: path, with: data)
    }
}

/// Applies edit operations to the JSON files of a loaded project and writes
/// only the files that changed, formatted the way Horizon writes them.
final class HorizontalProjectEditor {
    static let nullUUID = "00000000-0000-0000-0000-000000000000"
    /// Namespace for group and tag ids derived from their names, so the same
    /// name yields the same id in every project and every run.
    private static let groupTagNamespace = UUID(uuidString: "6e1f2b6c-5c0d-4d7e-9a3f-2b0f4a8c1d21")!

    private let project: HorizontalProject
    private let store: HorizontalProjectFileStore
    private let pool: HorizontalDispatchPoolIndex
    private let poolURL: URL?
    private var files: [String: JSONDictionary] = [:]
    private var fileURLs: [String: URL] = [:]
    private var dirty = Set<String>()
    private(set) var changes: [JSONDictionary] = []

    /// Which block this editor edits, and whether it is the top one. A board
    /// belongs to the top block: a sub-block's components are instantiated
    /// wherever it is used, so there is no single package to place for them.
    private(set) var blockID: String = ""
    private(set) var isTopBlock = true

    init(project: HorizontalProject, store: HorizontalProjectFileStore = HorizontalDiskFileStore(),
         snapshot: HorizontalDispatchSnapshot? = nil, block reference: String? = nil) throws {
        self.project = project
        self.store = store
        pool = HorizontalDispatchPoolIndex(project: project, snapshot: snapshot)
        poolURL = project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }

        let top = project.blocks.first(where: \.isTop)
        var selected = top
        if let reference, !reference.isEmpty {
            let matches = project.blocks.filter {
                $0.uuid.caseInsensitiveCompare(reference) == .orderedSame
                    || $0.displayName.caseInsensitiveCompare(reference) == .orderedSame
            }
            guard matches.count == 1, let match = matches.first else {
                if matches.isEmpty {
                    throw HorizontalDispatchError.notFound(
                        "No block \(reference). Blocks: \(project.blocks.map(\.displayName).joined(separator: ", "))."
                    )
                }
                throw HorizontalDispatchError.ambiguous("More than one block is called \(reference); use its uuid.",
                                                        candidates: matches.map(\.uuid))
            }
            selected = match
        }
        blockID = selected?.uuid ?? ""
        isTopBlock = selected?.isTop ?? true

        guard let blockFilename = selected?.blockFilename ?? (isTopBlock ? project.blockFilename : nil), !blockFilename.isEmpty else {
            throw HorizontalDispatchError.failed("Block \(selected?.displayName ?? "?") has no file to edit.")
        }
        try load("block", url: project.baseURL.appendingPathComponent(blockFilename))
        if let schematicFilename = selected?.schematicFilename ?? (isTopBlock ? project.schematicFilename : nil), !schematicFilename.isEmpty {
            try load("schematic", url: project.baseURL.appendingPathComponent(schematicFilename))
        }
        // The board is the top block's. Leaving it unloaded is what makes a
        // board op on a sub-block fail loudly instead of editing the wrong one.
        if isTopBlock, let boardFilename = project.boardFilename, !boardFilename.isEmpty {
            try load("board", url: project.baseURL.appendingPathComponent(boardFilename))
        }
    }

    private func load(_ key: String, url: URL) throws {
        guard let data = try store.read(url) else {
            return
        }
        files[key] = try JSONHelper.loadDictionary(from: data)
        fileURLs[key] = url
    }

    // MARK: - Applying

    func apply(_ operations: [HorizontalEditOperation]) throws {
        for operation in operations {
            try apply(operation)
        }
    }

    private func apply(_ operation: HorizontalEditOperation) throws {
        let params = operation.params
        var change: JSONDictionary = ["op": operation.kind.rawValue]
        switch operation.kind {
        case .ensureComponent:
            let (id, created) = try ensureComponent(params)
            change["component"] = id
            change["created"] = created
        case .removeComponent:
            let id = try componentID(params)
            change["component"] = id
            let notes = try textsNear(componentID: id, gateID: nil, sheet: nil, params)
            change["removed"] = removeComponent(id)
            if !notes.isEmpty { change["texts_removed"] = try removeFreeTexts(notes) }
        case .setValue:
            let id = try componentID(params)
            guard let value = params["value"] as? String else {
                throw HorizontalDispatchError.invalidParams("set_value needs \"value\".")
            }
            try updateComponent(id) { $0["value"] = value }
            change["component"] = id
            change["value"] = value
            // Horizon shows a part's own value over the component's, so a
            // value set on a part-backed component only matters once the
            // part is cleared or has no value of its own.
            if let partID = components()[id]?.string("part")?.lowercased(),
               let part = poolPart(partID), !part.value.isEmpty {
                change["note"] = "The part \(part.mpn) defines the value \(part.value), which Horizontal shows instead."
            }
        case .setRefdes:
            let id = try componentID(params)
            guard let refdes = params.string("refdes"), !refdes.isEmpty else {
                throw HorizontalDispatchError.invalidParams("set_refdes needs \"refdes\".")
            }
            try updateComponent(id) { $0["refdes"] = refdes }
            change["component"] = id
            change["refdes"] = refdes
        case .setPart:
            let id = try componentID(params)
            change["component"] = id
            change["cleared_connections"] = try setPart(id, partID: params["part"] as? String)
        case .setNoPopulate:
            let id = try componentID(params)
            guard let flag = params.bool("no_populate") else {
                throw HorizontalDispatchError.invalidParams("set_no_populate needs \"no_populate\".")
            }
            try updateComponent(id) { $0["nopopulate"] = flag }
            change["component"] = id
            change["no_populate"] = flag
        case .setGroupTag:
            let id = try componentID(params)
            let group = params["group"] as? String
            let tag = params["tag"] as? String
            try updateComponent(id) { component in
                component["group"] = self.nameID(group, table: "group_names")
                component["tag"] = self.nameID(tag, table: "tag_names")
            }
            change["component"] = id
            change["group"] = group ?? NSNull()
            change["tag"] = tag ?? NSNull()
        case .ensureNet:
            let (id, created) = try ensureNet(params)
            change["net"] = id
            change["created"] = created
        case .addBus:
            change.merge(try addBus(params)) { _, new in new }
        case .removeBus:
            change.merge(try removeBus(params)) { _, new in new }
        case .addBusMember:
            change.merge(try addBusMember(params)) { _, new in new }
        case .placeBusLabel:
            change.merge(try placeBusMark(params, kind: .label)) { _, new in new }
        case .placeBusRipper:
            change.merge(try placeBusMark(params, kind: .ripper)) { _, new in new }
        case .addNetTie:
            change.merge(try addNetTie(params)) { _, new in new }
        case .removeNetTie:
            change.merge(try removeNetTie(params)) { _, new in new }
        case .placeNetTie:
            change.merge(try placeNetTie(params)) { _, new in new }
        case .addNetClass:
            change.merge(try addNetClass(params)) { _, new in new }
        case .renameNetClass:
            change.merge(try renameNetClass(params)) { _, new in new }
        case .renameNet:
            let id = try netID(params)
            guard let name = params["name"] as? String else {
                throw HorizontalDispatchError.invalidParams("rename_net needs \"name\".")
            }
            try updateNet(id) { $0["name"] = name }
            change["net"] = id
            change["name"] = name
        case .setNetClass:
            let id = try netID(params)
            guard let netClass = params.string("net_class") else {
                throw HorizontalDispatchError.invalidParams("set_net_class needs \"net_class\".")
            }
            let classID = try netClassID(netClass)
            try updateNet(id) { $0["net_class"] = classID }
            change["net"] = id
            change["net_class"] = classID
        case .retireNet:
            let id = try netID(params)
            change["net"] = id
            change.merge(try retireNet(id, removeRouting: params.bool("remove_routing") ?? false)) { _, new in new }
        case .connect:
            let id = try componentID(params)
            let pin = try pinPath(params, componentID: id)
            let net: String
            if let existing = try? netID(params) {
                net = existing
            } else if params.bool("create_net") ?? false, let name = params.string("net") {
                net = try ensureNet(["name": name]).0
            } else {
                throw HorizontalDispatchError.notFound("No net matches \(params["net"] ?? "nothing"); pass create_net to make it.")
            }
            try updateComponent(id) { component in
                var connections = component["connections"] as? JSONDictionary ?? [:]
                connections[pin] = ["net": net]
                component["connections"] = connections
            }
            change["component"] = id
            change["pin"] = pin
            change["net"] = net
        case .disconnect:
            let id = try componentID(params)
            let pin = try pinPath(params, componentID: id)
            try updateComponent(id) { component in
                var connections = component["connections"] as? JSONDictionary ?? [:]
                connections.removeValue(forKey: pin)
                component["connections"] = connections
            }
            change["component"] = id
            change["pin"] = pin
        case .placeSymbol:
            let id = try componentID(params)
            change["component"] = id
            change.merge(try placeSymbol(id, params)) { _, new in new }
        case .removeSymbol:
            let id = try componentID(params)
            change["component"] = id
            let gateID = params.string("gate") == nil ? nil : try gate(params, componentID: id).id
            let notes = try textsNear(componentID: id, gateID: gateID, sheet: params["sheet"] == nil ? nil : try sheetID(params), params)
            change["removed"] = try removeSymbol(id, params)
            if !notes.isEmpty { change["texts_removed"] = try removeFreeTexts(notes) }
        case .drawNetLine:
            change.merge(try drawNetLine(params)) { _, new in new }
        case .placeJunction:
            change.merge(try placeJunction(params)) { _, new in new }
        case .setNetLineEndpoint:
            change.merge(try setNetLineEndpoint(params)) { _, new in new }
        case .removeNetLine:
            change.merge(try removeNetLine(params)) { _, new in new }
        case .removeJunction:
            change.merge(try removeJunction(params)) { _, new in new }
        case .pruneSheet:
            change.merge(try pruneSheets(params)) { _, new in new }
        case .terminatePin:
            change.merge(try terminatePin(params)) { _, new in new }
        case .setSymbolDisplay:
            change.merge(try setSymbolDisplay(params)) { _, new in new }
        case .setNoConnect:
            change.merge(try setNoConnect(params)) { _, new in new }
        case .remapPart:
            change.merge(try remapPart(params)) { _, new in new }
        case .placeText:
            change.merge(try placeText(params)) { _, new in new }
        case .removeText:
            change.merge(try removeText(params)) { _, new in new }
        case .placePowerSymbol:
            change.merge(try placePowerSymbol(params)) { _, new in new }
        case .removePowerSymbol:
            change.merge(try removeSheetMark(params, key: "power_symbols", label: "power symbol")) { _, new in new }
        case .placeNetLabel:
            change.merge(try placeNetLabel(params)) { _, new in new }
        case .removeNetLabel:
            change.merge(try removeSheetMark(params, key: "net_labels", label: "net label")) { _, new in new }
        case .addBlockInstance:
            change.merge(try addBlockInstance(params)) { _, new in new }
        case .removeBlockInstance:
            change.merge(try removeBlockInstance(params)) { _, new in new }
        case .connectBlockPort:
            change.merge(try connectBlockPort(params)) { _, new in new }
        case .placeBlockSymbol:
            change.merge(try placeBlockSymbol(params)) { _, new in new }
        case .removeBlockSymbol:
            change.merge(try removeBlockSymbol(params)) { _, new in new }
        case .addRule:
            change.merge(try addRule(params)) { _, new in new }
        case .setRule:
            change.merge(try setRule(params)) { _, new in new }
        case .removeRule:
            change.merge(try removeRule(params)) { _, new in new }
        case .setStackup:
            change.merge(try setStackup(params)) { _, new in new }
        case .addSheet:
            change.merge(try addSheet(params)) { _, new in new }
        case .renameSheet:
            change.merge(try renameSheet(params)) { _, new in new }
        case .removeSheet:
            change.merge(try removeSheet(params)) { _, new in new }
        case .placePolygon:
            change.merge(try placePolygon(params)) { _, new in new }
        case .removePolygon:
            change.merge(try removePolygon(params)) { _, new in new }
        case .placePlane:
            change.merge(try placePlane(params)) { _, new in new }
        case .removePlane:
            change.merge(try removePlane(params)) { _, new in new }
        case .placeHole:
            change.merge(try placeHole(params)) { _, new in new }
        case .removeHole:
            change.merge(try removeBoardEntry(params, key: "holes", selector: "hole", label: "hole")) { _, new in new }
        case .placeKeepout:
            change.merge(try placeKeepout(params)) { _, new in new }
        case .removeKeepout:
            change.merge(try removeKeepout(params)) { _, new in new }
        case .placeBoardText:
            change.merge(try placeBoardText(params)) { _, new in new }
        case .removeBoardText:
            change.merge(try removeBoardEntry(params, key: "texts", selector: "id", label: "board text")) { _, new in new }
        case .placeDimension:
            change.merge(try placeDimension(params)) { _, new in new }
        case .removeDimension:
            change.merge(try removeBoardEntry(params, key: "dimensions", selector: "dimension", label: "dimension")) { _, new in new }
        case .setSheetIndex:
            change.merge(try setSheetIndex(params)) { _, new in new }
        case .placeTrack:
            change.merge(try placeTrack(params)) { _, new in new }
        case .removeTrack:
            change.merge(try removeTrack(params)) { _, new in new }
        case .setTrackWidth:
            change.merge(try setTrackWidth(params)) { _, new in new }
        case .placeVia:
            change.merge(try placeVia(params)) { _, new in new }
        case .removeVia:
            change.merge(try removeVia(params)) { _, new in new }
        case .placeComponent:
            let id = try componentID(params)
            change["component"] = id
            change["package"] = try placeComponent(id, params)
        case .removePlacement:
            let id = try componentID(params)
            change["component"] = id
            change["removed_packages"] = removeBoardPackages(componentID: id)
        case .copyGroupLayout:
            let result = try copyGroupLayout(params)
            change.merge(result) { _, new in new }
        }
        changes.append(change)
    }

    // MARK: - Writing

    /// Writes every changed file and returns their paths. Files are written
    /// the way Horizon writes them (four-space indent, byte-ordered keys, no
    /// trailing newline), so an edit shows up in `git diff` as the lines it
    /// touched rather than a reformatted file.
    func write() throws -> [String] {
        var written = [String]()
        for key in dirty.sorted() {
            guard let json = files[key], let url = fileURLs[key] else {
                continue
            }
            let data = try HorizontalHorizonJSONWriter.data(json)
            try store.write(data, to: url)
            written.append(url.path)
        }
        return written
    }

    var changedFiles: [String] {
        dirty.sorted().compactMap { fileURLs[$0]?.path }
    }

    // MARK: - Components

    private var block: JSONDictionary {
        get { files["block"] ?? [:] }
        set { files["block"] = newValue; dirty.insert("block") }
    }

    private func components() -> [String: JSONDictionary] {
        block.dictionaryMap("components")
    }

    private func componentID(_ params: JSONDictionary) throws -> String {
        guard let reference = params.string("component"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Missing \"component\" (a reference designator or id).")
        }
        return try componentID(reference: reference)
    }

    private func componentID(reference: String) throws -> String {
        let all = components()
        if let match = all.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let byRefdes = all.filter { ($0.value.string("refdes") ?? "") == reference }
        if byRefdes.count == 1, let match = byRefdes.keys.first {
            return match
        }
        if byRefdes.count > 1 {
            throw HorizontalDispatchError.invalidParams("\(byRefdes.count) components are named \(reference); use the id.")
        }
        throw HorizontalDispatchError.notFound("No component \(reference).")
    }

    private func updateComponent(_ id: String, _ body: (inout JSONDictionary) -> Void) throws {
        var all = block["components"] as? JSONDictionary ?? [:]
        guard var component = all[id] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound("No component \(id).")
        }
        body(&component)
        all[id] = component
        block["components"] = all
    }

    private func ensureComponent(_ params: JSONDictionary) throws -> (String, Bool) {
        if let id = params.string("id")?.lowercased(), components()[id] != nil {
            return (id, false)
        }
        if params.string("id") == nil, let refdes = params.string("refdes"), let existing = try? componentID(reference: refdes) {
            return (existing, false)
        }
        var entityID = params.string("entity")?.lowercased()
        let partID = params.string("part")?.lowercased()
        if let partID {
            guard let part = poolPart(partID) else {
                throw HorizontalDispatchError.notFound("No pool part \(partID).")
            }
            entityID = part.entityID?.lowercased() ?? entityID
        }
        guard let entityID else {
            throw HorizontalDispatchError.invalidParams("ensure_component needs a \"part\" or an \"entity\".")
        }
        guard let entity = pool.entity(entityID) else {
            throw HorizontalDispatchError.notFound("No pool entity \(entityID).")
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        var component: JSONDictionary = [
            "alt_pins": [String: Any](),
            "connections": [String: Any](),
            "entity": entityID,
            "group": nameID(params.string("group"), table: "group_names"),
            "pin_names": [String: Any](),
            "refdes": params.string("refdes") ?? "\(entity.prefix.isEmpty ? "X" : entity.prefix)?",
            "tag": nameID(params.string("tag"), table: "tag_names"),
            "value": params.string("value") ?? ""
        ]
        if let partID {
            component["part"] = partID
        }
        var all = block["components"] as? JSONDictionary ?? [:]
        all[id] = component
        block["components"] = all
        return (id, true)
    }

    private func setPart(_ id: String, partID: String?) throws -> Bool {
        var clearedConnections = false
        if let partID {
            guard let part = poolPart(partID.lowercased()) else {
                throw HorizontalDispatchError.notFound("No pool part \(partID).")
            }
            try updateComponent(id) { component in
                let previousEntity = component.string("entity")?.lowercased()
                component["part"] = partID.lowercased()
                if let entityID = part.entityID?.lowercased() {
                    if let previousEntity, previousEntity != entityID {
                        component["connections"] = [String: Any]()
                        component["alt_pins"] = [String: Any]()
                        clearedConnections = true
                    }
                    component["entity"] = entityID
                }
            }
        } else {
            try updateComponent(id) { $0.removeValue(forKey: "part") }
        }
        return clearedConnections
    }

    private func removeComponent(_ id: String) -> JSONDictionary {
        var all = block["components"] as? JSONDictionary ?? [:]
        all.removeValue(forKey: id)
        block["components"] = all
        let symbols = removeSchematicSymbols(componentID: id)
        let packages = removeBoardPackages(componentID: id)
        return ["symbols": symbols, "packages": packages]
    }

    private func poolPart(_ id: String) -> HorizontalPoolPart? {
        if let part = project.poolParts.first(where: { $0.id.lowercased() == id }) {
            return part
        }
        guard !(store is HorizontalArchiveFileStore), let poolURL else {
            return nil
        }
        return HorizontalPoolPart.loadCached(id: id, from: poolURL)
    }

    // MARK: - Nets

    private func nets() -> [String: JSONDictionary] {
        block.dictionaryMap("nets")
    }

    private func netID(_ params: JSONDictionary) throws -> String {
        guard let reference = params.string("net"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Missing \"net\" (a name or id).")
        }
        return try netID(reference: reference)
    }

    private func netID(reference: String) throws -> String {
        let all = nets()
        if let match = all.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let byName = all.filter { ($0.value.string("name") ?? "") == reference }
        if byName.count == 1, let match = byName.keys.first {
            return match
        }
        if byName.count > 1 {
            throw HorizontalDispatchError.invalidParams("\(byName.count) nets are named \(reference); use the id.")
        }
        throw HorizontalDispatchError.notFound("No net \(reference).")
    }

    private func updateNet(_ id: String, _ body: (inout JSONDictionary) -> Void) throws {
        var all = block["nets"] as? JSONDictionary ?? [:]
        guard var net = all[id] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound("No net \(id).")
        }
        body(&net)
        all[id] = net
        block["nets"] = all
    }

    private func ensureNet(_ params: JSONDictionary) throws -> (String, Bool) {
        if let id = params.string("id")?.lowercased(), nets()[id] != nil {
            return (id, false)
        }
        guard let name = params.string("name"), !name.isEmpty else {
            throw HorizontalDispatchError.invalidParams("ensure_net needs a \"name\".")
        }
        if params.string("id") == nil, let existing = try? netID(reference: name) {
            return (existing, false)
        }
        let classID = try params.string("net_class").map(netClassID) ?? (block.string("net_class_default") ?? Self.nullUUID)
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        let net: JSONDictionary = [
            "is_port": false,
            "is_power": params.bool("is_power") ?? false,
            "name": name,
            "net_class": classID,
            "port_direction": "bidirectional",
            "power_symbol_name_visible": true,
            "power_symbol_style": "gnd"
        ]
        var all = block["nets"] as? JSONDictionary ?? [:]
        all[id] = net
        block["nets"] = all
        return (id, true)
    }

    private func addNetClass(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_net_class needs a \"name\".")
        }
        var classes = block["net_classes"] as? JSONDictionary ?? [:]
        if let existing = classes.first(where: { ($0.value as? JSONDictionary)?.string("name") == name }) {
            return ["net_class": existing.key, "name": name, "created": false]
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        guard classes[id] == nil else {
            throw HorizontalDispatchError.invalidParams("A net class \(id) already exists.")
        }
        classes[id] = ["name": name]
        block["net_classes"] = classes
        return ["net_class": id, "name": name, "created": true,
                "note": "Its parameters — widths, clearances — live in the board rules, not here."]
    }

    private func renameNetClass(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("net_class") else {
            throw HorizontalDispatchError.invalidParams("rename_net_class needs \"net_class\".")
        }
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("rename_net_class needs a \"name\".")
        }
        let id = try netClassID(reference)
        var classes = block["net_classes"] as? JSONDictionary ?? [:]
        var item = classes[id] as? JSONDictionary ?? [:]
        item["name"] = name
        classes[id] = item
        block["net_classes"] = classes
        return ["net_class": id, "name": name]
    }

    private func netClassID(_ reference: String) throws -> String {
        let classes = block.dictionaryMap("net_classes")
        if let match = classes.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        if let match = classes.first(where: { ($0.value.string("name") ?? "").caseInsensitiveCompare(reference) == .orderedSame }) {
            return match.key
        }
        throw HorizontalDispatchError.notFound("No net class \(reference). Known: \(classes.values.compactMap { $0.string("name") }.sorted().joined(separator: ", ")).")
    }

    private func retireNet(_ id: String, removeRouting: Bool) throws -> JSONDictionary {
        let id = id.lowercased()
        // What the schematic draws for the net, worked out while the net and
        // its connections still exist to resolve it.
        var drawn = [String: (lines: Set<String>, labels: Set<String>, power: Set<String>, junctions: Set<String>)]()
        if files["schematic"] != nil {
            for sheet in try sheetsInOrder() {
                let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet.json, block: block)
                func onNet(_ endpoint: JSONDictionary?) -> Bool { endpoint.flatMap { connectivity.net(at: $0) }?.lowercased() == id }
                let lines = sheet.json.dictionaryMap("net_lines").filter { _, line in
                    line.string("net")?.lowercased() == id || onNet(line.dictionary("from")) || onNet(line.dictionary("to"))
                }.keys
                let labels = sheet.json.dictionaryMap("net_labels").filter { _, label in
                    label.string("last_net")?.lowercased() == id || onNet(label.string("junction").map { ["junc": $0] as JSONDictionary })
                }.keys
                let power = sheet.json.dictionaryMap("power_symbols").filter { $0.value.string("net")?.lowercased() == id }.keys
                let junctions = sheet.json.dictionaryMap("junctions").filter { key, junction in
                    junction.string("net")?.lowercased() == id || onNet(["junc": key])
                }.keys
                if !(lines.isEmpty && labels.isEmpty && power.isEmpty && junctions.isEmpty) {
                    drawn[sheet.id] = (Set(lines), Set(labels), Set(power), Set(junctions))
                }
            }
        }
        // A net tie names the net on both sides; leaving one would tie to nothing.
        let ties = block.dictionaryMap("net_ties").filter {
            [$0.value.string("net_primary")?.lowercased(), $0.value.string("net_secondary")?.lowercased()].contains(id)
        }
        guard ties.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Net tie \(ties.keys.sorted().joined(separator: ", ")) joins this net; remove_net_tie it first.")
        }

        var all = block["nets"] as? JSONDictionary ?? [:]
        all.removeValue(forKey: all.keys.first { $0.lowercased() == id } ?? id)
        block["nets"] = all

        var disconnected = 0
        var componentsMap = block["components"] as? JSONDictionary ?? [:]
        for (componentID, value) in componentsMap {
            guard var component = value as? JSONDictionary,
                  var connections = component["connections"] as? JSONDictionary else {
                continue
            }
            let before = connections.count
            connections = connections.filter { ($0.value as? JSONDictionary)?.string("net")?.lowercased() != id }
            guard connections.count != before else {
                continue
            }
            disconnected += before - connections.count
            component["connections"] = connections
            componentsMap[componentID] = component
        }
        block["components"] = componentsMap

        // Block ports wired to it, and bus members carrying it, go with it.
        var ports = 0
        var instances = block.dictionaryMap("block_instances")
        for (instanceID, var instance) in instances {
            var connections = instance.dictionaryMap("connections")
            let before = connections.count
            connections = connections.filter { $0.value.string("net")?.lowercased() != id }
            guard connections.count != before else { continue }
            ports += before - connections.count
            instance["connections"] = connections
            instances[instanceID] = instance
        }
        if ports > 0 { block["block_instances"] = instances }
        var busMembers = Set<String>()
        var buses = block.dictionaryMap("buses")
        for (busID, var bus) in buses {
            var members = bus.dictionaryMap("members")
            let doomed = members.filter { $0.value.string("net")?.lowercased() == id }.keys
            guard !doomed.isEmpty else { continue }
            for member in doomed { members.removeValue(forKey: member); busMembers.insert(member.lowercased()) }
            bus["members"] = members
            buses[busID] = bus
        }
        if !busMembers.isEmpty { block["buses"] = buses }

        var counts = ["net_lines": 0, "net_labels": 0, "power_symbols": 0, "junctions": 0, "bus_rippers": 0]
        if files["schematic"] != nil {
            for sheet in try sheetsInOrder() {
                let marks = drawn[sheet.id]
                let rippers = sheet.json.dictionaryMap("bus_rippers").filter { busMembers.contains($0.value.string("member")?.lowercased() ?? "") }.keys
                guard marks != nil || !rippers.isEmpty else { continue }
                try updateSheet(sheet.id) { item in
                    for (key, doomed) in [("net_lines", marks?.lines ?? []), ("net_labels", marks?.labels ?? []),
                                          ("power_symbols", marks?.power ?? []), ("bus_rippers", Set(rippers))] where !doomed.isEmpty {
                        var map = item.dictionaryMap(key)
                        for markID in doomed { map.removeValue(forKey: markID) }
                        item[key] = map
                        counts[key, default: 0] += doomed.count
                    }
                }
                // Junctions of the net, once nothing else stands on them.
                let candidates = (marks?.junctions ?? []).union((marks?.lines ?? []).flatMap { line in
                    sheet.json.dictionaryMap("net_lines")[line].map { Array(Self.lineJunctions($0)) } ?? []
                })
                counts["junctions", default: 0] += try collectSheetJunctions(sheet.id, candidates: candidates).count
            }
        }

        // Board copper on the net, as the loaded board resolved it.
        var board: JSONDictionary = [:]
        if isTopBlock, let loaded = project.board, files["board"] != nil {
            let tracks = loaded.tracks.filter { $0.netID?.lowercased() == id }.map { $0.id.lowercased() }
            let vias = loaded.vias.filter { $0.netID?.lowercased() == id }.map { $0.id.lowercased() }
            let planes = (files["board"]?.dictionaryMap("planes") ?? [:]).filter { $0.value.string("net")?.lowercased() == id }
            board = ["tracks": tracks.count, "vias": vias.count, "planes": planes.count]
            if removeRouting, !(tracks.isEmpty && vias.isEmpty && planes.isEmpty) {
                try updateBoard { json in
                    for (key, doomed) in [("tracks", Set(tracks)), ("vias", Set(vias))] {
                        var map = json.dictionaryMap(key)
                        for itemID in map.keys where doomed.contains(itemID.lowercased()) { map.removeValue(forKey: itemID) }
                        json[key] = map
                    }
                    var planeMap = json.dictionaryMap("planes"), polygons = json.dictionaryMap("polygons")
                    for (planeID, plane) in planes {
                        planeMap.removeValue(forKey: planeID)
                        if let polygon = plane.string("polygon") { polygons.removeValue(forKey: polygon) }
                    }
                    json["planes"] = planeMap
                    json["polygons"] = polygons
                }
                board["junctions_removed"] = try collectJunctions().count
                board["removed"] = true
            } else if !(tracks.isEmpty && vias.isEmpty && planes.isEmpty) {
                board["removed"] = false
                board["note"] = "Copper on this net is left in place, on no net; pass remove_routing to remove it."
            }
        }
        var removed: JSONDictionary = ["connections": disconnected, "block_ports": ports, "bus_members": busMembers.count]
        for (key, count) in counts { removed[key] = count }
        var change: JSONDictionary = ["removed": removed]
        if !board.isEmpty { change["board"] = board }
        return change
    }

    // MARK: - Pin terminations

    /// The way a pin points out of its symbol's body, by its orientation.
    private static let outward: [String: (x: Double, y: Double)] = ["left": (-1, 0), "right": (1, 0), "up": (0, 1), "down": (0, -1)]

    private func terminatePin(_ params: JSONDictionary) throws -> JSONDictionary {
        let componentID = try componentID(params)
        let path = try pinPath(params, componentID: componentID)
        let refdes = components()[componentID]?.string("refdes") ?? componentID
        let name = pinName(path, componentID: componentID)
        let connection = components()[componentID]?.dictionary("connections")?.first { $0.key.lowercased() == path }?.value as? JSONDictionary
        let current = connection?.string("net")?.lowercased()
        let net: String
        if params["net"] != nil {
            if let existing = try? netID(params) {
                net = existing.lowercased()
            } else if params.bool("create_net") ?? false, let name = params.string("net") {
                net = try ensureNet(["name": name]).0
            } else {
                throw HorizontalDispatchError.notFound("No net matches \(params["net"] ?? "nothing"); pass create_net to make it.")
            }
            if let current, current != net {
                throw HorizontalDispatchError.invalidParams(
                    "\(refdes) pin \(name) is on \(nets()[current]?.string("name") ?? current), not \(nets()[net]?.string("name") ?? net); disconnect it first."
                )
            }
        } else {
            guard let current else {
                throw HorizontalDispatchError.invalidParams("\(refdes) pin \(name) is on no net; pass \"net\" to end it on one.")
            }
            net = current
        }
        if current == nil {
            try updateComponent(componentID) { component in
                var connections = component["connections"] as? JSONDictionary ?? [:]
                connections.removeValue(forKey: connections.keys.first { $0.lowercased() == path } ?? path)
                connections[path] = ["net": net]
                component["connections"] = connections
            }
        }
        let gateID = String(path.split(separator: "/")[0]), pinID = String(path.split(separator: "/")[1])
        guard let instance = try symbolInstance(componentID: componentID, gateID: gateID) else {
            throw HorizontalDispatchError.notFound("The gate of \(refdes) holding pin \(name) is not on a sheet; place_symbol it first.")
        }
        guard let symbol = instance.json.string("symbol"), let geometry = pool.symbolPin(symbol, pin: pinID) else {
            throw HorizontalDispatchError.invalidParams("The symbol drawing \(refdes) does not draw pin \(name).")
        }
        let transform = (HorizontalPlacementTransform(json: instance.json.dictionary("placement")) ?? .identity).schematicGeometry
        let direction = Self.outward[geometry.orientation] ?? (1, 0)
        let tip = transform.applying(to: geometry.position)
        let ahead = transform.applying(to: HorizontalPoint(x: geometry.position.x + direction.x * 1_000_000,
                                                           y: geometry.position.y + direction.y * 1_000_000))
        let dx = ((ahead.x - tip.x) / 1_000_000).rounded(), dy = ((ahead.y - tip.y) / 1_000_000).rounded()
        let facing = dx < 0 ? "left" : dx > 0 ? "right" : dy > 0 ? "up" : "down"
        let length = params.double("length_mm") ?? 2.54
        guard length > 0 else { throw HorizontalDispatchError.invalidParams("length_mm must be more than zero.") }
        let end = (x: tip.x / 1_000_000 + dx * length, y: tip.y / 1_000_000 + dy * length)

        let kind = params.string("kind") ?? (nets()[net]?.bool("is_power") == true ? "power" : "label")
        var mark: JSONDictionary = ["net": net, "sheet": instance.sheet, "x_mm": end.x, "y_mm": end.y, "orientation": facing]
        let placed: JSONDictionary
        switch kind {
        case "power":
            if let style = params.string("style") { mark["style"] = style }
            placed = try placePowerSymbol(mark)
        case "label":
            if let size = params.double("size_mm") { mark["size_mm"] = size }
            placed = try placeNetLabel(mark)
        default:
            throw HorizontalDispatchError.invalidParams("kind must be label or power.")
        }
        guard let junction = placed.string("junction") else { throw HorizontalDispatchError.failed("The mark has no junction.") }
        let wire = try drawTypedNetLine([:], from: ["kind": "pin", "symbol": instance.id, "pin": pinID],
                                        to: ["kind": "junction", "junction": junction])
        var change: JSONDictionary = ["component": componentID, "pin": path, "pin_name": name, "net": net, "sheet": instance.sheet,
                                      "connected": current == nil, "kind": kind, "orientation": facing, "junction": junction,
                                      "net_line": wire["net_line"] as Any,
                                      "x_mm": HorizontalDispatchJSON.mm(end.x * 1_000_000), "y_mm": HorizontalDispatchJSON.mm(end.y * 1_000_000)]
        change[kind == "power" ? "power_symbol" : "net_label"] = placed[kind == "power" ? "power_symbol" : "net_label"]
        return change
    }

    // MARK: - No-connect

    /// Horizon marks a pin deliberately unconnected with a connection that
    /// names no net, which is what the app's no-connect tool writes.
    private func setNoConnect(_ params: JSONDictionary) throws -> JSONDictionary {
        let componentID = try componentID(params)
        let references = (params["pins"] as? [String] ?? []) + (params.string("pin").map { [$0] } ?? [])
        guard !references.isEmpty else { throw HorizontalDispatchError.invalidParams("set_no_connect needs \"pin\" or \"pins\".") }
        let mark = params.bool("no_connect") ?? true
        let disconnect = params.bool("disconnect") ?? false
        let refdes = components()[componentID]?.string("refdes") ?? componentID
        var paths = [String]()
        var taken = [JSONDictionary]()
        var connections = components()[componentID]?.dictionary("connections") ?? [:]
        for reference in references {
            var selector: JSONDictionary = ["pin": reference]
            if let gate = params.string("gate") { selector["gate"] = gate }
            let path = try pinPath(selector, componentID: componentID)
            let key = connections.keys.first { $0.lowercased() == path } ?? path
            let net = (connections[key] as? JSONDictionary)?.string("net")
            if mark {
                if let net {
                    guard disconnect else {
                        throw HorizontalDispatchError.invalidParams(
                            "\(refdes) pin \(pinName(path, componentID: componentID)) is on \(nets()[net.lowercased()]?.string("name") ?? net); pass disconnect to take it off and mark it."
                        )
                    }
                    taken.append(["pin": path, "net": net])
                }
                connections.removeValue(forKey: key)
                connections[path] = ["net": NSNull()]
            } else if connections[key] != nil, net == nil {
                connections.removeValue(forKey: key)
            }
            paths.append(path)
        }
        try updateComponent(componentID) { $0["connections"] = connections }
        var change: JSONDictionary = ["component": componentID, "pins": paths, "no_connect": mark]
        if !taken.isEmpty { change["disconnected"] = taken }
        return change
    }

    // MARK: - Pins

    /// Resolves the `pin` parameter to Horizon's `gate uuid/pin uuid` key.
    ///
    /// The whole reference is tried as a pin name or uuid first, because pin
    /// names carry slashes of their own — `PA13(JTMS/SWDIO)` — and only then
    /// split as gate/pin. A `gate` parameter narrows the search to one gate.
    private func pinPath(_ params: JSONDictionary, componentID: String) throws -> String {
        guard let reference = params.string("pin"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Missing \"pin\".")
        }
        guard let component = components()[componentID], let entityID = component.string("entity")?.lowercased() else {
            throw HorizontalDispatchError.notFound("Component \(componentID) has no entity.")
        }
        guard let entity = pool.entity(entityID) else {
            throw HorizontalDispatchError.notFound("Pool entity \(entityID) for \(componentID) is not in the project pool.")
        }
        let refdes = component.string("refdes") ?? componentID
        let only = params.string("gate") == nil ? nil : try gate(params, componentID: componentID).id
        let gates = entity.gates.filter { only == nil || $0.key == only }

        var matches = [String]()
        var duplicated = [String]()
        for (gateID, gate) in gates.sorted(by: { $0.key < $1.key }) {
            guard let unitID = gate.unitID, let unit = pool.unit(unitID) else { continue }
            if let pinID = pinID(reference, in: unit) {
                matches.append("\(gateID)/\(pinID)")
            } else if unit.pins.values.filter({ $0.name.caseInsensitiveCompare(reference) == .orderedSame }).count > 1 {
                duplicated.append(gate.name)
            }
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw HorizontalDispatchError.invalidParams(
                "Pin \(reference) is on \(matches.count) gates of \(refdes) (\(entity.name)); pass \"gate\" or name it as gate/pin."
            )
        }
        if !duplicated.isEmpty {
            throw HorizontalDispatchError.ambiguous(
                "More than one pin of \(refdes) is called \(reference); name it by pin uuid. get_component lists them.",
                candidates: gates.flatMap { gateID, gate -> [String] in
                    guard let unitID = gate.unitID, let unit = pool.unit(unitID) else { return [] }
                    return unit.pins.filter { $0.value.name.caseInsensitiveCompare(reference) == .orderedSame }.keys.map { "\(gateID)/\($0)" }
                }.sorted()
            )
        }
        // gate/pin, at every slash: a gate name may hold one as well.
        if only == nil {
            var index = reference.startIndex
            while let slash = reference[index...].firstIndex(of: "/") {
                let gateReference = String(reference[..<slash])
                let pinReference = String(reference[reference.index(after: slash)...])
                index = reference.index(after: slash)
                let gateMatches = entity.gates.filter { gateID, gate in
                    gateID.caseInsensitiveCompare(gateReference) == .orderedSame
                        || gate.name.caseInsensitiveCompare(gateReference) == .orderedSame
                        || (!gate.suffix.isEmpty && gate.suffix.caseInsensitiveCompare(gateReference) == .orderedSame)
                }
                guard gateMatches.count == 1, let (gateID, gate) = gateMatches.first,
                      let unitID = gate.unitID, let unit = pool.unit(unitID) else { continue }
                if let pinID = pinID(pinReference, in: unit) { return "\(gateID)/\(pinID)" }
            }
        }
        let names = gates.values.compactMap { $0.unitID.flatMap { pool.unit($0) } }
            .flatMap { $0.pins.values.map(\.name) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let listed = names.prefix(80).joined(separator: ", ") + (names.count > 80 ? ", … (\(names.count) in all)" : "")
        throw HorizontalDispatchError.notFound(
            "No pin \(reference) on \(refdes) (\(entity.name))\(only == nil ? "" : " gate \(entity.gates[only!]?.name ?? only!)"). Pins: \(listed)."
        )
    }

    private func pinID(_ reference: String, in unit: HorizontalDispatchPoolIndex.Unit) -> String? {
        if let match = unit.pins.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let byName = unit.pins.filter { $0.value.name.caseInsensitiveCompare(reference) == .orderedSame }
        return byName.count == 1 ? byName.keys.first : nil
    }

    /// A pin's name, for messages.
    private func pinName(_ path: String, componentID: String) -> String {
        let pieces = path.split(separator: "/").map(String.init)
        guard pieces.count == 2, let entityID = components()[componentID]?.string("entity"),
              let unitID = pool.entity(entityID)?.gates[pieces[0].lowercased()]?.unitID,
              let name = pool.unit(unitID)?.pins[pieces[1].lowercased()]?.name, !name.isEmpty else { return path }
        return name
    }

    // MARK: - Groups and tags

    private func nameID(_ name: String?, table: String) -> String {
        guard let name, !name.isEmpty else {
            return Self.nullUUID
        }
        var names = block[table] as? JSONDictionary ?? [:]
        if let existing = names.first(where: { ($0.value as? String) == name }) {
            return existing.key
        }
        let id = UUID.horizonUUID5(namespace: Self.groupTagNamespace, name: Array("\(table):\(name)".utf8)).uuidString.lowercased()
        names[id] = name
        block[table] = names
        return id
    }

    // MARK: - Schematic

    /// The sheets of the top block's schematic, in page order.
    private func sheetsInOrder() throws -> [(id: String, json: JSONDictionary)] {
        guard let schematic = files["schematic"] else {
            throw HorizontalDispatchError.notFound("The project has no schematic to draw on.")
        }
        return (schematic["sheets"] as? JSONDictionary ?? [:])
            .compactMap { id, value in (value as? JSONDictionary).map { (id, $0) } }
            .sorted { ($0.1.int("index") ?? 0, $0.0) < ($1.1.int("index") ?? 0, $1.0) }
    }

    /// Resolves the `sheet` parameter — a page number, a name or a uuid — to
    /// one sheet. Without it, the first sheet.
    private func sheetID(_ params: JSONDictionary) throws -> String {
        let sheets = try sheetsInOrder()
        guard let first = sheets.first else {
            throw HorizontalDispatchError.notFound("The schematic has no sheets.")
        }
        guard let reference = params["sheet"], !(reference is NSNull) else {
            return first.id
        }
        if let index = params.int("sheet"), !(reference is String) {
            guard let match = sheets.first(where: { $0.json.int("index") == index }) else {
                throw HorizontalDispatchError.notFound("No sheet \(index). Sheets: \(sheets.map { "\($0.json.int("index") ?? 0) \($0.json.string("name") ?? "")" }.joined(separator: ", ")).")
            }
            return match.id
        }
        guard let text = params.string("sheet") else {
            throw HorizontalDispatchError.invalidParams("sheet must be a sheet index, name or uuid.")
        }
        if let match = sheets.first(where: { $0.id.caseInsensitiveCompare(text) == .orderedSame }) {
            return match.id
        }
        let named = sheets.filter { ($0.json.string("name") ?? "").caseInsensitiveCompare(text) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("\(named.count) sheets are named \(text); pass the uuid.", candidates: named.map(\.id))
        }
        guard let match = named.first else {
            throw HorizontalDispatchError.notFound("No sheet \(text). Sheets: \(sheets.map { $0.json.string("name") ?? $0.id }.joined(separator: ", ")).")
        }
        return match.id
    }

    private func updateSheet(_ sheetID: String, _ body: (inout JSONDictionary) throws -> Void) throws {
        guard var schematic = files["schematic"] else {
            throw HorizontalDispatchError.notFound("The project has no schematic.")
        }
        var sheets = schematic["sheets"] as? JSONDictionary ?? [:]
        guard var sheet = sheets[sheetID] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound("No sheet \(sheetID).")
        }
        try body(&sheet)
        sheets[sheetID] = sheet
        schematic["sheets"] = sheets
        files["schematic"] = schematic
        dirty.insert("schematic")
    }

    /// Resolves the `gate` parameter against a component's entity. Optional
    /// when the entity has exactly one gate.
    private func gate(_ params: JSONDictionary, componentID: String, key: String = "gate") throws -> (id: String, gate: HorizontalDispatchPoolIndex.Gate) {
        guard let entityID = components()[componentID]?.string("entity")?.lowercased() else {
            throw HorizontalDispatchError.notFound("Component \(componentID) has no entity.")
        }
        guard let entity = pool.entity(entityID) else {
            throw HorizontalDispatchError.notFound("Pool entity \(entityID) for \(componentID) is not in the project pool.")
        }
        guard let reference = params.string(key), !reference.isEmpty else {
            guard entity.gates.count == 1, let only = entity.gates.first else {
                throw HorizontalDispatchError.invalidParams(
                    "\(entity.name) has \(entity.gates.count) gates; pass \"\(key)\". Gates: \(entity.gates.values.map { $0.suffix.isEmpty ? $0.name : $0.suffix }.sorted().joined(separator: ", "))."
                )
            }
            return (only.key, only.value)
        }
        let matches = entity.gates.filter { id, gate in
            id.caseInsensitiveCompare(reference) == .orderedSame
                || gate.name.caseInsensitiveCompare(reference) == .orderedSame
                || (!gate.suffix.isEmpty && gate.suffix.caseInsensitiveCompare(reference) == .orderedSame)
        }
        guard matches.count == 1, let match = matches.first else {
            throw HorizontalDispatchError.notFound("No gate \(reference) on \(entity.name). Gates: \(entity.gates.values.map(\.name).sorted().joined(separator: ", ")).")
        }
        return (match.key, match.value)
    }

    /// Every symbol instance on every sheet, as (sheetID, instanceID, item).
    private func symbolInstances() throws -> [(sheet: String, id: String, json: JSONDictionary)] {
        try sheetsInOrder().flatMap { sheet in
            sheet.json.dictionaryMap("symbols")
                .sorted { $0.key < $1.key }
                .map { (sheet.id, $0.key, $0.value) }
        }
    }

    private func symbolInstance(componentID: String, gateID: String) throws -> (sheet: String, id: String, json: JSONDictionary)? {
        let matches = try symbolInstances().filter {
            $0.json.string("component")?.lowercased() == componentID
                && $0.json.string("gate")?.lowercased() == gateID.lowercased()
        }
        guard matches.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("Gate is drawn more than once; select a symbol instance.", candidates: matches.map(\.id))
        }
        return matches.first
    }

    private func placeSymbol(_ componentID: String, _ params: JSONDictionary) throws -> JSONDictionary {
        let (gateID, resolvedGate) = try gate(params, componentID: componentID)
        let existing = try symbolInstance(componentID: componentID, gateID: gateID)
        // Without a sheet, a gate already drawn stays where it is and a new one
        // goes on the first sheet.
        let targetSheet: String
        if params["sheet"] == nil, let existing {
            targetSheet = existing.sheet
        } else {
            targetSheet = try sheetID(params)
        }
        var item = existing?.json ?? [:]

        // A gate is drawn by a symbol for its unit. Naming one is optional
        // while the project pool holds a single symbol that draws the unit;
        // more than one is a choice the caller has to make.
        if let requested = params.string("symbol")?.lowercased() {
            item["symbol"] = requested
        } else if item["symbol"] == nil {
            guard let unitID = resolvedGate.unitID else {
                throw HorizontalDispatchError.notFound("Gate \(resolvedGate.name) names no unit, so nothing draws it.")
            }
            let symbols = pool.symbols(forUnit: unitID)
            guard !symbols.isEmpty else {
                throw HorizontalDispatchError.notFound(
                    "No symbol in the project pool draws unit \(unitID). Import the part with import_pool_part, or pass \"symbol\"."
                )
            }
            guard symbols.count == 1 else {
                throw HorizontalDispatchError.ambiguous("\(symbols.count) symbols draw unit \(unitID); pass \"symbol\".", candidates: symbols)
            }
            item["symbol"] = symbols[0]
        }
        item["component"] = componentID
        item["gate"] = gateID
        if item["pin_display_mode"] == nil { item["pin_display_mode"] = "selected_only" }
        try Self.applySymbolDisplay(params, to: &item)

        var placement = item["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Int((x * 1_000_000).rounded()), Int((y * 1_000_000).rounded())]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_symbol needs \"x_mm\" and \"y_mm\" for a gate that is not on a sheet yet.")
        }
        if let degrees = params.double("angle_deg") {
            placement["angle"] = Self.horizonAngle(degrees)
        }
        if let mirror = params.bool("mirror") {
            placement["mirror"] = mirror
        }
        item["placement"] = placement

        let instanceID: String
        if let existing {
            if let requested = params.string("id"), requested.caseInsensitiveCompare(existing.id) != .orderedSame {
                throw HorizontalDispatchError.invalidParams("This gate is already drawn as \(existing.id); id only names a new symbol instance.")
            }
            instanceID = existing.id
        } else {
            instanceID = try editObjectID(params)
            guard try !symbolInstances().contains(where: { $0.id.caseInsensitiveCompare(instanceID) == .orderedSame }) else {
                throw HorizontalDispatchError.invalidParams("Symbol instance id already exists: \(instanceID).")
            }
        }
        // Moving a gate to another sheet takes its net lines' endpoints with
        // it, which this editor cannot redraw; make the caller do it in two
        // explicit steps instead of leaving lines pointing at nothing.
        if let existing, existing.sheet != targetSheet {
            throw HorizontalDispatchError.invalidParams(
                "\(instanceID) is already on another sheet. Remove it with remove_symbol, then place it on \(targetSheet)."
            )
        }
        try updateSheet(targetSheet) { sheet in
            var symbols = sheet["symbols"] as? JSONDictionary ?? [:]
            symbols[instanceID] = item
            sheet["symbols"] = symbols
        }
        return ["gate": gateID, "sheet": targetSheet, "symbol_instance": instanceID,
                "symbol": item.string("symbol") as Any, "created": existing == nil]
    }

    static let pinDisplayModes = ["selected_only", "custom_only", "both", "all"]

    private static func applySymbolDisplay(_ params: JSONDictionary, to item: inout JSONDictionary) throws {
        if let mode = params.string("pin_display_mode") {
            guard pinDisplayModes.contains(mode) else {
                throw HorizontalDispatchError.invalidParams("pin_display_mode must be one of \(pinDisplayModes.joined(separator: ", ")).")
            }
            item["pin_display_mode"] = mode
        }
        if let all = params.bool("display_all_pads") { item["display_all_pads"] = all }
    }

    private func setSymbolDisplay(_ params: JSONDictionary) throws -> JSONDictionary {
        guard params["pin_display_mode"] != nil || params["display_all_pads"] != nil else {
            throw HorizontalDispatchError.invalidParams("set_symbol_display needs pin_display_mode or display_all_pads.")
        }
        let targets: [(sheet: String, id: String, json: JSONDictionary)]
        if let instance = params.string("symbol_instance") {
            targets = try symbolInstances().filter { $0.id.caseInsensitiveCompare(instance) == .orderedSame }
            guard !targets.isEmpty else { throw HorizontalDispatchError.notFound("No symbol instance \(instance). list_symbols returns them.") }
        } else {
            let componentID = try componentID(params)
            let gateID = params.string("gate") == nil ? nil : try gate(params, componentID: componentID).id
            targets = try symbolInstances().filter {
                $0.json.string("component")?.lowercased() == componentID
                    && (gateID == nil || $0.json.string("gate")?.lowercased() == gateID)
            }
            guard !targets.isEmpty else { throw HorizontalDispatchError.notFound("No symbol for \(componentID) is on a sheet.") }
        }
        for target in targets {
            try updateSheet(target.sheet) { sheet in
                var symbols = sheet.dictionaryMap("symbols")
                guard var item = symbols[target.id] else { return }
                try Self.applySymbolDisplay(params, to: &item)
                symbols[target.id] = item
                sheet["symbols"] = symbols
            }
        }
        return ["symbol_instances": targets.map(\.id).sorted(),
                "pin_display_mode": params["pin_display_mode"] ?? NSNull(), "display_all_pads": params["display_all_pads"] ?? NSNull()]
    }

    private func removeSymbol(_ componentID: String, _ params: JSONDictionary) throws -> JSONDictionary {
        // No gate named means every gate of this component comes off.
        let gateID = params.string("gate") == nil ? nil : try gate(params, componentID: componentID).id
        let sheetFilter = params["sheet"] == nil ? nil : try sheetID(params)
        let doomed = try symbolInstances().filter { instance in
            instance.json.string("component")?.lowercased() == componentID
                && (gateID == nil || instance.json.string("gate")?.lowercased() == gateID)
                && (sheetFilter == nil || instance.sheet == sheetFilter)
        }
        guard !doomed.isEmpty else {
            throw HorizontalDispatchError.notFound("No symbol for \(componentID) is on a sheet.")
        }
        var lines = 0
        for instance in doomed {
            try updateSheet(instance.sheet) { sheet in
                var symbols = sheet["symbols"] as? JSONDictionary ?? [:]
                symbols.removeValue(forKey: instance.id)
                sheet["symbols"] = symbols
                var netLines = sheet["net_lines"] as? JSONDictionary ?? [:]
                let before = netLines.count
                netLines = netLines.filter { _, value in
                    guard let line = value as? JSONDictionary else { return true }
                    return !["from", "to"].contains { end in
                        line.dictionary(end)?.string("pin")?.split(separator: "/").first
                            .map { $0.lowercased() == instance.id.lowercased() } ?? false
                    }
                }
                lines += before - netLines.count
                sheet["net_lines"] = netLines
            }
        }
        return ["symbols": doomed.count, "net_lines": lines]
    }

    /// The wire between two pins the block already ties to one net. Horizon
    /// derives connectivity from the block, not from these lines, so drawing
    /// one records a decision rather than making it — and drawing one where
    /// the block disagrees would draw a lie.
    private func drawNetLine(_ params: JSONDictionary) throws -> JSONDictionary {
        if params["from"] != nil || params["to"] != nil {
            guard ["component", "pin", "to_component", "to_pin"].allSatisfy({ params[$0] == nil }),
                  let from = params.dictionary("from"), let to = params.dictionary("to") else {
                throw HorizontalDispatchError.invalidParams("Use from/to endpoints or all four legacy component/pin fields.")
            }
            return try drawTypedNetLine(params, from: from, to: to)
        }
        let fromComponent = try componentID(params)
        let fromPin = try pinPath(params, componentID: fromComponent)
        guard let toReference = params.string("to_component"), let toPinReference = params.string("to_pin") else {
            throw HorizontalDispatchError.invalidParams("draw_net_line needs \"to_component\" and \"to_pin\".")
        }
        let toComponent = try componentID(reference: toReference)
        var toSelector: JSONDictionary = ["pin": toPinReference]
        if let toGate = params.string("to_gate") { toSelector["gate"] = toGate }
        let toPin = try pinPath(toSelector, componentID: toComponent)

        func net(_ component: String, _ pin: String) throws -> String {
            guard let net = (components()[component]?["connections"] as? JSONDictionary)?
                .dictionary(pin)?.string("net")?.lowercased() else {
                throw HorizontalDispatchError.notFound("\(component) pin \(pin) is on no net. Connect it first.")
            }
            return net
        }
        let fromNet = try net(fromComponent, fromPin)
        let toNet = try net(toComponent, toPin)
        guard fromNet == toNet else {
            throw HorizontalDispatchError.invalidParams(
                "The two pins are on different nets (\(fromNet), \(toNet)); connect them to one net before drawing the wire."
            )
        }

        func endpoint(_ component: String, _ pin: String) throws -> (sheet: String, path: String) {
            let gateID = String(pin.split(separator: "/")[0])
            guard let instance = try symbolInstance(componentID: component, gateID: gateID) else {
                throw HorizontalDispatchError.notFound("\(component) gate \(gateID) is not on a sheet; place_symbol it first.")
            }
            let pinID = String(pin.split(separator: "/")[1])
            return (instance.sheet, "\(instance.id)/\(pinID)")
        }
        let from = try endpoint(fromComponent, fromPin)
        let to = try endpoint(toComponent, toPin)
        guard from.sheet == to.sheet else {
            throw HorizontalDispatchError.invalidParams(
                "The two gates are on different sheets; a net line stays on one sheet. Nets cross sheets through their names."
            )
        }
        if let sheet = params["sheet"], !(sheet is NSNull) {
            let requested = try sheetID(params)
            guard requested == from.sheet else {
                throw HorizontalDispatchError.invalidParams("Both gates are on sheet \(from.sheet), not \(requested).")
            }
        }

        var lineID = try editObjectID(params)
        var created = true
        try updateSheet(from.sheet) { sheet in
            var lines = sheet["net_lines"] as? JSONDictionary ?? [:]
            let ends = Set([from.path.lowercased(), to.path.lowercased()])
            if let existing = lines.first(where: { _, value in
                guard let line = value as? JSONDictionary else { return false }
                return Set(["from", "to"].compactMap { line.dictionary($0)?.string("pin")?.lowercased() }) == ends
            }) {
                lineID = existing.key
                created = false
                return
            }
            guard lines[lineID] == nil else { throw HorizontalDispatchError.invalidParams("Wire id already exists: \(lineID).") }
            lines[lineID] = ["from": Self.pinEndpoint(from.path), "to": Self.pinEndpoint(to.path), "net": fromNet]
            sheet["net_lines"] = lines
        }
        return ["net_line": lineID, "sheet": from.sheet, "net": fromNet, "created": created,
                "from": ["component": fromComponent, "pin": fromPin], "to": ["component": toComponent, "pin": toPin]]
    }

    private func editObjectID(_ params: JSONDictionary) throws -> String {
        guard let id = params.string("id") else { return UUID().uuidString.lowercased() }
        guard UUID(uuidString: id) != nil else { throw HorizontalDispatchError.invalidParams("id must be a UUID.") }
        return id.lowercased()
    }

    private struct WireEnd {
        var sheet: String
        /// Nil only for a junction with no net yet, which takes the net of
        /// whatever it is wired to.
        var net: String?
        var json: JSONDictionary
        var identity: String
        var junction: String? = nil
    }

    private func wireEnd(_ endpoint: JSONDictionary, sheet selected: String? = nil) throws -> WireEnd {
        if endpoint.string("kind") == "pin" {
            guard Set(endpoint.keys).isSubset(of: ["kind", "symbol", "pin", "component", "gate"]),
                  let pinReference = endpoint.string("pin"), !pinReference.isEmpty,
                  (endpoint["symbol"] == nil) != (endpoint["component"] == nil) else {
                throw HorizontalDispatchError.invalidParams(
                    "A pin endpoint is {kind: pin, symbol: <instance id>, pin: <name or uuid>} or {kind: pin, component: <refdes>, gate?: <gate>, pin: <name or uuid>}."
                )
            }
            let instance: (sheet: String, id: String, json: JSONDictionary)
            if let symbolID = endpoint.string("symbol") {
                let matches = try symbolInstances().filter { $0.id.caseInsensitiveCompare(symbolID) == .orderedSame && (selected == nil || selected == $0.sheet) }
                guard matches.count == 1, let match = matches.first else {
                    throw HorizontalDispatchError.notFound("No symbol instance \(symbolID)\(selected == nil ? "" : " on that sheet"). list_symbols returns them.")
                }
                instance = match
            } else {
                let componentID = try componentID(reference: endpoint.string("component") ?? "")
                let gateID = endpoint.string("gate") == nil ? nil : try gate(endpoint, componentID: componentID).id
                var drawn = try symbolInstances().filter {
                    $0.json.string("component")?.lowercased() == componentID && (selected == nil || selected == $0.sheet)
                        && (gateID == nil || $0.json.string("gate")?.lowercased() == gateID)
                }
                if drawn.count > 1 {
                    // Which gate holds the pin decides it.
                    let path = try pinPath(["pin": pinReference], componentID: componentID)
                    let holder = String(path.split(separator: "/")[0])
                    drawn = drawn.filter { $0.json.string("gate")?.lowercased() == holder }
                }
                guard drawn.count == 1, let match = drawn.first else {
                    throw HorizontalDispatchError.notFound(drawn.isEmpty
                        ? "\(endpoint.string("component") ?? componentID) has no symbol\(selected == nil ? "" : " on that sheet") to wire to; place_symbol it first."
                        : "\(endpoint.string("component") ?? componentID) is drawn more than once; name the symbol instance.")
                }
                instance = match
            }
            guard let component = instance.json.string("component")?.lowercased(), let gate = instance.json.string("gate")?.lowercased() else {
                throw HorizontalDispatchError.invalidParams("Symbol instance \(instance.id) names no component and gate.")
            }
            let path = try pinPath(["pin": pinReference, "gate": gate], componentID: component)
            let pinID = String(path.split(separator: "/")[1])
            let refdes = components()[component]?.string("refdes") ?? component
            let name = pinName(path, componentID: component)
            guard let symbol = instance.json.string("symbol"), pool.symbolHasPin(symbol, pin: pinID) else {
                throw HorizontalDispatchError.invalidParams("The symbol drawing \(refdes) does not draw pin \(name), so there is nothing to wire to.")
            }
            let connection = components()[component]?.dictionary("connections")?.first { $0.key.lowercased() == path }?.value as? JSONDictionary
            guard let net = connection?.string("net")?.lowercased(), block.dictionaryMap("nets")[net] != nil
                    || block.dictionaryMap("nets").keys.contains(where: { $0.lowercased() == net }) else {
                throw HorizontalDispatchError.invalidParams(connection == nil
                    ? "\(refdes) pin \(name) is on no net. Connect it first (connect); a wire records a connection the block already makes."
                    : "\(refdes) pin \(name) is marked no-connect. Connect it to a net first.")
            }
            return WireEnd(sheet: instance.sheet, net: net, json: Self.pinEndpoint("\(instance.id)/\(pinID)"), identity: "pin/\(instance.id)/\(pinID)")
        }
        guard endpoint.string("kind") == "junction", Set(endpoint.keys) == ["kind", "junction"],
              let id = endpoint.string("junction")?.lowercased() else {
            throw HorizontalDispatchError.invalidParams("An endpoint is {kind: pin, symbol, pin}, {kind: pin, component, gate?, pin} or {kind: junction, junction}.")
        }
        let matches = try sheetsInOrder().filter { selected == nil || selected == $0.id }.flatMap { sheet in
            sheet.json.dictionaryMap("junctions").filter { $0.key.lowercased() == id }.map { (sheet: sheet.id, id: $0.key, json: $0.value) }
        }
        guard matches.count == 1, let junction = matches.first,
              let sheet = try sheetsInOrder().first(where: { $0.id == junction.sheet }) else {
            throw HorizontalDispatchError.notFound("No junction \(id)\(selected == nil ? "" : " on that sheet"). list_junctions returns them.")
        }
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet.json, block: block)
        let endpointJSON: JSONDictionary = ["junc": junction.id, "pin": NSNull(), "port": NSNull(), "bus_ripper": NSNull()]
        let net = connectivity.net(at: ["junc": junction.id])
        if net == nil {
            let named = connectivity.namedNets(at: ["junc": junction.id])
            let known = Set(block.dictionaryMap("nets").keys.map { $0.lowercased() })
            // Floating, or still naming a net that is gone: either way it can
            // take a net. Two live nets meeting is a short to fix, not adopt.
            guard named.intersection(known).isEmpty else {
                throw HorizontalDispatchError.invalidParams("Junction \(id) is wired to more than one net (\(named.sorted().joined(separator: ", "))); fix that before wiring to it.")
            }
        }
        return WireEnd(sheet: junction.sheet, net: net?.lowercased(), json: endpointJSON, identity: "junc/\(junction.id)", junction: junction.id)
    }

    /// Gives a net-less junction a net, so the wire about to reach it carries one.
    private func adoptJunction(_ id: String, sheet: String, net: String) throws {
        try updateSheet(sheet) { sheet in
            var junctions = sheet.dictionaryMap("junctions")
            guard let key = junctions.keys.first(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return }
            junctions[key]?["net"] = net
            sheet["junctions"] = junctions
        }
    }

    private func drawTypedNetLine(_ params: JSONDictionary, from: JSONDictionary, to: JSONDictionary) throws -> JSONDictionary {
        let sheet = try params["sheet"].map { _ in try sheetID(params) }
        let start = try wireEnd(from, sheet: sheet)
        let end = try wireEnd(to, sheet: sheet)
        guard start.sheet == end.sheet else {
            throw HorizontalDispatchError.invalidParams("Wire endpoints are on different sheets; a wire stays on one sheet. Nets cross sheets through their labels.")
        }
        guard start.identity != end.identity else {
            throw HorizontalDispatchError.invalidParams("A wire needs two distinct endpoints.")
        }
        guard let net = start.net ?? end.net else {
            throw HorizontalDispatchError.invalidParams("Neither end is on a net. Wire one end to a pin, label or power symbol, or place_junction it on a net.")
        }
        guard (start.net ?? net) == net, (end.net ?? net) == net else {
            throw HorizontalDispatchError.invalidParams("The endpoints are on different nets (\(start.net!), \(end.net!)); a wire joins one net.")
        }
        var adopted = [String]()
        for wireEnd in [start, end] where wireEnd.net == nil {
            if let junction = wireEnd.junction {
                try adoptJunction(junction, sheet: start.sheet, net: net)
                adopted.append(junction)
            }
        }
        var id = try editObjectID(params)
        var created = true
        try updateSheet(start.sheet) { sheet in
            var lines = sheet.dictionaryMap("net_lines")
            let a = HorizontalSchematicNetConnectivity.endpointID(start.json), b = HorizontalSchematicNetConnectivity.endpointID(end.json)
            if let existing = lines.first(where: { _, line in
                guard let f = line.dictionary("from"), let t = line.dictionary("to") else { return false }
                let from = HorizontalSchematicNetConnectivity.endpointID(f), to = HorizontalSchematicNetConnectivity.endpointID(t)
                return (a == from && b == to) || (a == to && b == from)
            }) { id = existing.key; created = false }
            else {
                guard lines[id] == nil else { throw HorizontalDispatchError.invalidParams("Wire id already exists: \(id).") }
                lines[id] = ["from": start.json, "to": end.json, "net": net]
                sheet["net_lines"] = lines
            }
        }
        var change: JSONDictionary = ["net_line": id, "sheet": start.sheet, "net": net, "created": created]
        if !adopted.isEmpty { change["adopted_junctions"] = adopted }
        return change
    }

    private func placeJunction(_ params: JSONDictionary) throws -> JSONDictionary {
        let sheet = try sheetID(params), net = try netID(params)
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_junction needs x_mm and y_mm.")
        }
        let point = [Self.nanometres(x), Self.nanometres(y)]
        var id = try editObjectID(params)
        var created = true
        try updateSheet(sheet) { sheet in
            let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet, block: block)
            var junctions = sheet.dictionaryMap("junctions")
            let coincident = junctions.filter { $0.value["position"] as? [Int] == point }
            let known = Set(block.dictionaryMap("nets").keys.map { $0.lowercased() })
            let floating = { (id: String) in
                connectivity.net(at: ["junc": id]) == nil && connectivity.namedNets(at: ["junc": id]).intersection(known).isEmpty
            }
            guard coincident.keys.allSatisfy({ connectivity.net(at: ["junc": $0]) == net || floating($0) }), coincident.count <= 1 else {
                throw HorizontalDispatchError.invalidParams("A different or ambiguous net already has a junction at this point.")
            }
            if let existing = coincident.first {
                id = existing.key
                created = false
                if floating(existing.key) {
                    junctions[existing.key]?["net"] = net
                    sheet["junctions"] = junctions
                }
            }
            else {
                guard junctions[id] == nil else { throw HorizontalDispatchError.invalidParams("Junction id already exists: \(id).") }
                junctions[id] = ["position": point, "net": net]
                sheet["junctions"] = junctions
            }
        }
        return ["junction": id, "sheet": sheet, "net": net, "created": created]
    }

    private func setNetLineEndpoint(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let id = params.string("line")?.lowercased(), let end = params.string("end"), ["from", "to"].contains(end),
              let endpoint = params.dictionary("endpoint") else {
            throw HorizontalDispatchError.invalidParams("set_net_line_endpoint needs line, end (from/to), and endpoint.")
        }
        let selected = try params["sheet"].map { _ in try sheetID(params) }
        let matches = try sheetsInOrder().filter { selected == nil || selected == $0.id }.flatMap { sheet in
            sheet.json.dictionaryMap("net_lines").filter { $0.key.lowercased() == id }.map { (sheet.id, $0.key, $0.value) }
        }
        guard matches.count == 1, let line = matches.first else { throw HorizontalDispatchError.notFound("Wire \(id) is missing or ambiguous.") }
        let replacement = try wireEnd(endpoint, sheet: line.0)
        guard let sheet = try sheetsInOrder().first(where: { $0.id == line.0 }) else {
            throw HorizontalDispatchError.notFound("The wire's sheet is missing.")
        }
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet.json, block: block)
        let other = end == "from" ? "to" : "from"
        guard let original = line.2.dictionary(end),
              let wireNet = connectivity.net(at: original) ?? line.2.dictionary(other).flatMap({ connectivity.net(at: $0) }) else {
            throw HorizontalDispatchError.invalidParams("The wire is on no net, so there is nothing to keep it on; remove_net_line it instead.")
        }
        guard (replacement.net ?? wireNet) == wireNet else {
            throw HorizontalDispatchError.invalidParams("Replacement endpoint is on \(replacement.net!), not the wire's net \(wireNet).")
        }
        let otherJSON = line.2.dictionary(other) ?? [:]
        let otherSelector: JSONDictionary
        if let junction = otherJSON.string("junc") {
            otherSelector = ["kind": "junction", "junction": junction]
        } else if let path = otherJSON.string("pin"), path.split(separator: "/").count == 2 {
            let pieces = path.split(separator: "/").map(String.init)
            otherSelector = ["kind": "pin", "symbol": pieces[0], "pin": pieces[1]]
        } else {
            throw HorizontalDispatchError.unsupported("Retargeting currently requires a pin or junction at the opposite end.")
        }
        guard (try wireEnd(otherSelector, sheet: line.0).net ?? wireNet) == wireNet else {
            throw HorizontalDispatchError.invalidParams("The opposite endpoint no longer agrees with the wire's logical net.")
        }
        guard HorizontalSchematicNetConnectivity.endpointID(replacement.json) != HorizontalSchematicNetConnectivity.endpointID(otherJSON) else {
            throw HorizontalDispatchError.invalidParams("A wire must have distinct endpoints.")
        }
        if replacement.net == nil, let junction = replacement.junction {
            try adoptJunction(junction, sheet: line.0, net: wireNet)
        }
        try updateSheet(line.0) { sheet in
            var lines = sheet.dictionaryMap("net_lines")
            lines[line.1]?[end] = replacement.json
            sheet["net_lines"] = lines
        }
        var change: JSONDictionary = ["net_line": line.1, "sheet": line.0, "end": end, "net": wireNet]
        if replacement.net == nil, let junction = replacement.junction { change["adopted_junctions"] = [junction] }
        return change
    }

    /// Explicit substitution, leaving both the source and imported pool items
    /// untouched. All edits remain in this editor until the transaction validates.
    private func remapPart(_ params: JSONDictionary) throws -> JSONDictionary {
        let componentID = try componentID(params)
        guard let component = components()[componentID],
              let targetID = params.string("part")?.lowercased(), let target = poolPart(targetID),
              let entityID = target.entityID?.lowercased(), let targetEntity = pool.entity(entityID) else {
            throw HorizontalDispatchError.invalidParams("remap_part needs a part in the project pool; import_pool_part brings one in.")
        }
        guard params["pin_map"] == nil || params["pin_map"] is [String: String] else {
            throw HorizontalDispatchError.invalidParams("pin_map must map gateUUID/pinUUID strings to gateUUID/pinUUID strings.")
        }
        let rawMap = params["pin_map"] as? [String: String] ?? [:]
        func identity(_ path: String, entity: HorizontalDispatchPoolIndex.Entity) -> Bool {
            let pieces = path.split(separator: "/").map(String.init)
            return pieces.count == 2 && entity.gates[pieces[0]]?.unitID.flatMap { pool.unit($0)?.pins[pieces[1]] } != nil
        }
        guard let oldEntityID = component.string("entity"), let oldEntity = pool.entity(oldEntityID) else {
            throw HorizontalDispatchError.notFound("The old entity is missing.")
        }
        var mapping = [String: String]()
        for (old, new) in rawMap {
            let old = old.lowercased(), new = new.lowercased()
            guard mapping[old] == nil, identity(old, entity: oldEntity), identity(new, entity: targetEntity) else {
                throw HorizontalDispatchError.invalidParams("pin_map must contain unique, existing gateUUID/pinUUID identities: \(old) → \(new).")
            }
            mapping[old] = new
        }
        guard Set(mapping.values).count == mapping.count else {
            throw HorizontalDispatchError.invalidParams("pin_map must not merge two old pins into one target pin.")
        }
        // Whatever pin_map leaves out is matched by name: the gate by name,
        // suffix, or as the only gate, then each pin by its primary name.
        // Pins sharing a name (VSS, VDD) pair up in a stable order.
        var automatic = 0
        var sharedNames = Set<String>()
        let explicit = Set(mapping.keys)
        var used = Set(mapping.values)
        for (oldGateID, oldGate) in oldEntity.gates.sorted(by: { $0.key < $1.key }) {
            let candidates = targetEntity.gates.filter { $0.value.name.caseInsensitiveCompare(oldGate.name) == .orderedSame }
            let bySuffix = targetEntity.gates.filter { !oldGate.suffix.isEmpty && $0.value.suffix.caseInsensitiveCompare(oldGate.suffix) == .orderedSame }
            let only = oldEntity.gates.count == 1 && targetEntity.gates.count == 1 ? targetEntity.gates : [:]
            guard let (newGateID, newGate) = (candidates.count == 1 ? candidates.first : bySuffix.count == 1 ? bySuffix.first : only.first),
                  let oldUnit = oldGate.unitID.flatMap({ pool.unit($0) }), let newUnit = newGate.unitID.flatMap({ pool.unit($0) }) else { continue }
            let oldByName = Dictionary(grouping: oldUnit.pins.keys.sorted()) { oldUnit.pins[$0]!.name.lowercased() }
            let newByName = Dictionary(grouping: newUnit.pins.keys.sorted()) { newUnit.pins[$0]!.name.lowercased() }
            for (name, oldPins) in oldByName {
                let newPins = (newByName[name] ?? []).filter { !used.contains("\(newGateID)/\($0)") }
                if oldPins.count > 1 || newPins.count > 1 { sharedNames.insert(oldUnit.pins[oldPins[0]]!.name) }
                for (oldPin, newPin) in zip(oldPins.filter { !explicit.contains("\(oldGateID)/\($0)") }, newPins) {
                    mapping["\(oldGateID)/\(oldPin)"] = "\(newGateID)/\(newPin)"
                    used.insert("\(newGateID)/\(newPin)")
                    automatic += 1
                }
            }
        }
        // Every pin something depends on must have come through one way or
        // the other; name the ones that did not, rather than the first.
        let needed = Set((component.dictionary("connections") ?? [:]).keys.map { $0.lowercased() })
            .union((component.dictionary("alt_pins") ?? [:]).keys.map { $0.lowercased() })
        let unmapped = needed.subtracting(mapping.keys).sorted()
        guard unmapped.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "\(unmapped.count) connected pins have no counterpart by name on the new part: \(unmapped.prefix(40).map { pinName($0, componentID: componentID) }.joined(separator: ", ")). Map them in pin_map; nothing was changed."
            )
        }
        var connections = JSONDictionary(), altPins = JSONDictionary()
        for (key, value) in component.dictionary("connections") ?? [:] {
            guard let new = mapping[key.lowercased()] else {
                throw HorizontalDispatchError.invalidParams("Connected pin \(key) has no mapping; nothing was changed.")
            }
            connections[new] = value
        }
        for (key, value) in component.dictionary("alt_pins") ?? [:] {
            guard let new = mapping[key.lowercased()] else {
                throw HorizontalDispatchError.invalidParams("Alternate pin \(key) has no mapping.")
            }
            altPins[new] = value
        }
        let requestedSymbols = try stringMap(params, key: "symbols")
        guard Set(requestedSymbols.keys).isSubset(of: Set(targetEntity.gates.keys)) else {
            throw HorizontalDispatchError.invalidParams("symbols contains an unknown target gate.")
        }
        var symbolUpdates = [String: (sheet: String, item: JSONDictionary)]()
        var wirePins = [String: String]()
        var drawnTargetGates = Set<String>()
        for instance in try symbolInstances() where instance.json.string("component")?.lowercased() == componentID {
            guard let oldGate = instance.json.string("gate")?.lowercased() else { continue }
            let gateMap = mapping.filter { $0.key.hasPrefix(oldGate + "/") }
            let newGates = Set(gateMap.values.compactMap { $0.split(separator: "/").first.map(String.init) })
            guard newGates.count == 1, let gate = newGates.first, drawnTargetGates.insert(gate).inserted,
                  let unit = targetEntity.gates[gate]?.unitID else {
                throw HorizontalDispatchError.invalidParams("Each drawn gate needs one distinct target gate in pin_map.")
            }
            let choices = pool.symbols(forUnit: unit)
            let symbol: String
            if let requested = requestedSymbols[gate], choices.contains(requested) { symbol = requested }
            else if requestedSymbols[gate] == nil, choices.count == 1 { symbol = choices[0] }
            else { throw HorizontalDispatchError.invalidParams("Choose a valid symbol for target gate \(gate) using symbols.") }
            var item = instance.json
            item["gate"] = gate
            item["symbol"] = symbol
            symbolUpdates[instance.id.lowercased()] = (instance.sheet, item)
            for (old, new) in gateMap {
                let oldPin = String(old.split(separator: "/")[1]), newPin = String(new.split(separator: "/")[1])
                guard pool.symbolHasPin(symbol, pin: newPin) else {
                    throw HorizontalDispatchError.invalidParams("Target symbol does not draw mapped pin \(newPin).")
                }
                wirePins["\(instance.id)/\(oldPin)".lowercased()] = "\(instance.id)/\(newPin)"
            }
        }
        var changedWires = 0
        for page in try sheetsInOrder() {
            try updateSheet(page.id) { sheet in
                var symbols = sheet.dictionaryMap("symbols"), lines = sheet.dictionaryMap("net_lines")
                for (id, _) in symbols {
                    if let replacement = symbolUpdates[id.lowercased()] { symbols[id] = replacement.item }
                }
                for (id, var line) in lines {
                    var changed = false
                    for end in ["from", "to"] {
                        guard var endpoint = line.dictionary(end), let path = endpoint.string("pin")?.lowercased(),
                              let instance = path.split(separator: "/").first.map(String.init), symbolUpdates[instance] != nil else { continue }
                        guard let newPath = wirePins[path] else {
                            throw HorizontalDispatchError.invalidParams("Wired pin \(path) has no mapping.")
                        }
                        endpoint["pin"] = newPath
                        line[end] = endpoint
                        changed = true
                    }
                    if changed { lines[id] = line; changedWires += 1 }
                }
                sheet["symbols"] = symbols
                sheet["net_lines"] = lines
            }
        }
        // Board packages derive their footprint from the component's part.
        // Copper endpoints, however, retain pad UUIDs and must be translated.
        var padMapping = try stringMap(params, key: "pad_map")
        let oldPart = component.string("part")
        let oldPads = oldPart.map { pool.terminals(partID: $0) } ?? []
        let targetPads = pool.terminals(partID: targetID)
        for (old, new) in padMapping {
            guard let terminal = oldPads.first(where: { $0.string("id")?.lowercased() == old }),
                  let oldPath = terminal.string("gate_pin_path")?.lowercased(), let newPath = mapping[oldPath],
                  targetPads.contains(where: { $0.string("id")?.lowercased() == new && $0.string("gate_pin_path")?.lowercased() == newPath }) else {
                throw HorizontalDispatchError.invalidParams("pad_map must follow the explicit logical pin mapping.")
            }
        }
        for terminal in oldPads {
            guard let id = terminal.string("id")?.lowercased(), padMapping[id] == nil,
                  let path = terminal.string("gate_pin_path")?.lowercased(), let newPath = mapping[path] else { continue }
            let matches = targetPads.filter { $0.string("gate_pin_path")?.lowercased() == newPath }
            if matches.count == 1 { padMapping[id] = matches[0].string("id") }
        }
        if isTopBlock, files["board"] != nil {
            try updateBoard { board in
                let packageIDs = Set(board.dictionaryMap("packages").filter { $0.value.string("component")?.lowercased() == componentID }.keys.map { $0.lowercased() })
                var tracks = board.dictionaryMap("tracks")
                for (id, var track) in tracks {
                    for end in ["from", "to"] {
                        guard var endpoint = track.dictionary(end), let path = endpoint.string("pad") else { continue }
                        let pieces = path.lowercased().split(separator: "/").map(String.init)
                        guard pieces.count == 2, packageIDs.contains(pieces[0]) else { continue }
                        guard let pad = padMapping[pieces[1]] else {
                            throw HorizontalDispatchError.invalidParams("Routed pad \(pieces[1]) needs an unambiguous pad_map entry.")
                        }
                        endpoint["pad"] = "\(pieces[0])/\(pad)"
                        track[end] = endpoint
                    }
                    tracks[id] = track
                }
                board["tracks"] = tracks
            }
        }
        try updateComponent(componentID) { component in
            component["part"] = targetID
            component["entity"] = entityID
            component["connections"] = connections
            component["alt_pins"] = altPins
        }
        var change: JSONDictionary = ["component": componentID, "part": targetID, "pin_map": mapping, "pad_map": padMapping,
                                      "preserved_connections": connections.count, "symbols": symbolUpdates.count, "net_lines": changedWires,
                                      "explicitly_mapped": explicit.count, "mapped_by_name": automatic]
        if !sharedNames.isEmpty { change["paired_shared_names"] = sharedNames.sorted() }
        return change
    }

    private func stringMap(_ params: JSONDictionary, key: String) throws -> [String: String] {
        guard let value = params[key] else { return [:] }
        guard let map = value as? [String: String] else { throw HorizontalDispatchError.invalidParams("\(key) must map string identities to string identities.") }
        var result = [String: String]()
        for (key, value) in map {
            guard result[key.lowercased()] == nil else { throw HorizontalDispatchError.invalidParams("Duplicate identity \(key).") }
            result[key.lowercased()] = value.lowercased()
        }
        return result
    }

    // MARK: - Wire cleanup

    /// One wire, by id, on any sheet or the one named.
    private func netLine(_ params: JSONDictionary, key: String = "line") throws -> (sheet: String, id: String, json: JSONDictionary) {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required; list_net_lines returns the ids.")
        }
        let selected = try params["sheet"].map { _ in try sheetID(params) }
        let matches = try sheetsInOrder().filter { selected == nil || selected == $0.id }.flatMap { sheet in
            sheet.json.dictionaryMap("net_lines").filter { $0.key.caseInsensitiveCompare(reference) == .orderedSame }
                .map { (sheet: sheet.id, id: $0.key, json: $0.value) }
        }
        guard matches.count == 1, let match = matches.first else {
            throw HorizontalDispatchError.notFound("No wire \(reference)\(selected == nil ? "" : " on that sheet"). list_net_lines returns them.")
        }
        return match
    }

    private static func lineJunctions(_ line: JSONDictionary) -> Set<String> {
        Set(["from", "to"].compactMap { line.dictionary($0)?.string("junc")?.lowercased() })
    }

    private func removeNetLine(_ params: JSONDictionary) throws -> JSONDictionary {
        let line = try netLine(params)
        try updateSheet(line.sheet) { sheet in
            var lines = sheet.dictionaryMap("net_lines")
            lines.removeValue(forKey: line.id)
            sheet["net_lines"] = lines
        }
        return ["net_line": line.id, "sheet": line.sheet,
                "junctions_removed": try collectSheetJunctions(line.sheet, candidates: Self.lineJunctions(line.json))]
    }

    private func removeJunction(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("junction"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove_junction needs \"junction\"; list_junctions returns the ids.")
        }
        let selected = try params["sheet"].map { _ in try sheetID(params) }
        let matches = try sheetsInOrder().filter { selected == nil || selected == $0.id }.compactMap { sheet -> (sheet: String, id: String, json: JSONDictionary)? in
            guard let key = sheet.json.dictionaryMap("junctions").keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else { return nil }
            return (sheet.id, key, sheet.json)
        }
        guard matches.count == 1, let match = matches.first else {
            throw HorizontalDispatchError.notFound("No junction \(reference)\(selected == nil ? "" : " on that sheet"). list_junctions returns them.")
        }
        let id = match.id.lowercased()
        let lines = match.json.dictionaryMap("net_lines").filter { Self.lineJunctions($0.value).contains(id) }
        var marks = [String: [String]]()
        for key in ["net_labels", "power_symbols", "bus_labels", "bus_rippers"] {
            let on = match.json.dictionaryMap(key).filter { $0.value.string("junction")?.lowercased() == id }.keys.sorted()
            if !on.isEmpty { marks[key] = on }
        }
        let ties = match.json.dictionaryMap("net_ties").filter { _, tie in ["from", "to"].contains { tie.string($0)?.lowercased() == id } }
        guard ties.isEmpty else {
            throw HorizontalDispatchError.invalidParams("A net tie is drawn on junction \(match.id); remove_net_tie it first.")
        }
        guard params.bool("cascade") ?? true || (lines.isEmpty && marks.isEmpty) else {
            throw HorizontalDispatchError.invalidParams(
                "Junction \(match.id) still holds \(lines.count) wires and \(marks.values.map(\.count).reduce(0, +)) labels or symbols; pass cascade to remove them too."
            )
        }
        try updateSheet(match.sheet) { sheet in
            var junctions = sheet.dictionaryMap("junctions")
            junctions.removeValue(forKey: match.id)
            sheet["junctions"] = junctions
            var netLines = sheet.dictionaryMap("net_lines")
            for key in lines.keys { netLines.removeValue(forKey: key) }
            sheet["net_lines"] = netLines
            for (key, ids) in marks {
                var map = sheet.dictionaryMap(key)
                for markID in ids { map.removeValue(forKey: markID) }
                sheet[key] = map
            }
        }
        // The far ends of the wires taken with it may be left holding nothing.
        let farEnds = lines.values.reduce(into: Set<String>()) { $0.formUnion(Self.lineJunctions($1)) }.subtracting([id])
        var change: JSONDictionary = ["junction": match.id, "sheet": match.sheet, "net_lines": lines.keys.sorted(),
                                      "junctions_removed": try collectSheetJunctions(match.sheet, candidates: farEnds)]
        for (key, ids) in marks { change[key] = ids }
        return change
    }

    /// Drawing left behind once what it drew is gone: wires with an end that
    /// names nothing, wiring that carries no net and reaches no pin, labels on
    /// no net, and junctions nothing stands on.
    private func pruneSheets(_ params: JSONDictionary) throws -> JSONDictionary {
        let targets = params["sheet"] == nil ? try sheetsInOrder().map(\.id) : [try sheetID(params)]
        let known = Set(block.dictionaryMap("nets").keys.map { $0.lowercased() })
        let componentsMap = components()
        var report = [JSONDictionary]()
        for target in targets {
            guard let sheet = try sheetsInOrder().first(where: { $0.id == target })?.json else { continue }
            let junctionIDs = Set(sheet.dictionaryMap("junctions").keys.map { $0.lowercased() })
            let symbols = sheet.dictionaryMap("symbols")
            let symbolIDs = Set(symbols.keys.map { $0.lowercased() })
            func dangling(_ end: JSONDictionary?) -> Bool {
                guard let end, HorizontalSchematicNetConnectivity.endpointID(end) != nil else { return true }
                if let junction = end.string("junc") { return !junctionIDs.contains(junction.lowercased()) }
                if let pin = end.string("pin") {
                    let pieces = pin.lowercased().split(separator: "/").map(String.init)
                    guard pieces.count == 2, symbolIDs.contains(pieces[0]),
                          let symbol = symbols.first(where: { $0.key.lowercased() == pieces[0] })?.value.string("symbol") else { return true }
                    return !pool.symbolHasPin(symbol, pin: pieces[1])
                }
                return false
            }
            let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet, block: block)
            func floating(_ endpoint: JSONDictionary) -> Bool {
                guard let id = HorizontalSchematicNetConnectivity.endpointID(endpoint), let island = connectivity.islandOf[id] else { return true }
                let members = connectivity.islands[island].members
                return connectivity.islands[island].nets.intersection(known).isEmpty && members.allSatisfy { $0.hasPrefix("junc/") }
            }
            var doomedLines = Set<String>()
            for (id, line) in sheet.dictionaryMap("net_lines") {
                if dangling(line.dictionary("from")) || dangling(line.dictionary("to")) || line.dictionary("from").map(floating) ?? true {
                    doomedLines.insert(id)
                }
            }
            var doomedLabels = [String]()
            for (id, label) in sheet.dictionaryMap("net_labels") {
                guard let junction = label.string("junction") else { doomedLabels.append(id); continue }
                let named = connectivity.namedNets(at: ["junc": junction]).intersection(known)
                if !junctionIDs.contains(junction.lowercased()) || (named.isEmpty && !known.contains(label.string("last_net")?.lowercased() ?? "")) {
                    doomedLabels.append(id)
                }
            }
            var doomedPower = sheet.dictionaryMap("power_symbols").filter { !known.contains($0.value.string("net")?.lowercased() ?? "") }.keys.sorted()
            // A symbol whose component is gone is drawn from nothing.
            let doomedSymbols = symbols.filter { componentsMap[$0.value.string("component")?.lowercased() ?? ""] == nil }.keys.sorted()
            // Wiring that reaches no pin is debris whatever its marks name.
            var islands = [JSONDictionary]()
            if params.bool("unanchored") ?? false {
                let nets = block.dictionaryMap("nets")
                for island in HorizontalSchematicDebris(sheet: sheet, block: block, symbolHasPin: pool.symbolHasPin).unanchored {
                    doomedLines.formUnion(island.lines)
                    doomedLabels.append(contentsOf: island.labels.filter { !doomedLabels.contains($0) })
                    doomedPower.append(contentsOf: island.powerSymbols.filter { !doomedPower.contains($0) })
                    var entry: JSONDictionary = ["net_lines": island.lines.count, "net_labels": island.labels.count,
                                                 "power_symbols": island.powerSymbols.count,
                                                 "nets": island.nets.map { nets[$0]?.string("name") ?? $0 }.sorted()]
                    if let point = HorizontalSchematicDebris.point(island.position) { entry["at"] = point }
                    islands.append(entry)
                }
            }
            let trimStubs = params.bool("stubs") ?? false
            guard !doomedLines.isEmpty || !doomedLabels.isEmpty || !doomedPower.isEmpty || !doomedSymbols.isEmpty || trimStubs
                    || !junctionIDs.isSubset(of: Self.referencedJunctions(sheet)) else { continue }
            try updateSheet(target) { sheet in
                var lines = sheet.dictionaryMap("net_lines")
                for id in doomedLines { lines.removeValue(forKey: id) }
                sheet["net_lines"] = lines
                var labels = sheet.dictionaryMap("net_labels")
                for id in doomedLabels { labels.removeValue(forKey: id) }
                sheet["net_labels"] = labels
                var power = sheet.dictionaryMap("power_symbols")
                for id in doomedPower { power.removeValue(forKey: id) }
                sheet["power_symbols"] = power
                var drawn = sheet.dictionaryMap("symbols")
                for id in doomedSymbols { drawn.removeValue(forKey: id) }
                sheet["symbols"] = drawn
            }
            // Lines that ended on a removed symbol go too.
            if !doomedSymbols.isEmpty {
                let gone = Set(doomedSymbols.map { $0.lowercased() })
                try updateSheet(target) { sheet in
                    var lines = sheet.dictionaryMap("net_lines")
                    for (id, line) in lines where ["from", "to"].contains(where: { end in
                        line.dictionary(end)?.string("pin")?.lowercased().split(separator: "/").first.map { gone.contains(String($0)) } ?? false
                    }) {
                        lines.removeValue(forKey: id)
                        doomedLines.insert(id)
                    }
                    sheet["net_lines"] = lines
                }
            }
            // A dead end goes back to where it branched: the same runs
            // find_dangling reports, taken whole.
            var stubs = [JSONDictionary]()
            if trimStubs, let current = try sheetsInOrder().first(where: { $0.id == target })?.json {
                let found = HorizontalSchematicDebris(sheet: current, block: block, symbolHasPin: pool.symbolHasPin).stubs
                if !found.isEmpty {
                    let doomed = Set(found.flatMap(\.lines))
                    try updateSheet(target) { sheet in
                        var lines = sheet.dictionaryMap("net_lines")
                        for id in doomed { lines.removeValue(forKey: id) }
                        sheet["net_lines"] = lines
                    }
                    doomedLines.formUnion(doomed)
                }
                stubs = found.map { stub in
                    var entry: JSONDictionary = ["net_lines": stub.lines.count, "junctions": stub.junctions.count]
                    if let point = HorizontalSchematicDebris.point(stub.position) { entry["at"] = point }
                    return entry
                }
            }
            let junctions = try collectSheetJunctions(target)
            guard !(doomedLines.isEmpty && doomedLabels.isEmpty && doomedPower.isEmpty && doomedSymbols.isEmpty && junctions.isEmpty) else { continue }
            var entry: JSONDictionary = ["sheet": target, "name": sheet.string("name") as Any, "net_lines": doomedLines.sorted(),
                                         "net_labels": doomedLabels.sorted(), "power_symbols": doomedPower.sorted(), "symbols": doomedSymbols,
                                         "junctions": junctions]
            if !islands.isEmpty { entry["unanchored_islands"] = islands }
            if !stubs.isEmpty { entry["stubs"] = stubs }
            report.append(entry)
        }
        var removed = JSONDictionary()
        for key in ["net_lines", "net_labels", "power_symbols", "symbols", "junctions"] {
            removed[key] = report.reduce(0) { total, sheet in total + ((sheet[key] as? [String])?.count ?? 0) }
        }
        // Counts a compact reply keeps, to set beside find_dangling's totals.
        for key in ["unanchored_islands", "stubs"] {
            let count = report.reduce(0) { total, sheet in total + ((sheet[key] as? [JSONDictionary])?.count ?? 0) }
            if count > 0 { removed[key] = count }
        }
        return ["pruned": report, "removed": removed]
    }

    // MARK: - Sheet texts

    static let textOrigins = ["baseline", "center", "bottom"]
    static let textFonts = ["simplex", "complex", "complex_italic", "complex_small",
                            "complex_small_italic", "duplex", "triplex", "triplex_italic"]

    /// Every free text on every sheet, as (sheetID, textID, item).
    private func sheetTexts() throws -> [(sheet: String, id: String, json: JSONDictionary)] {
        try sheetsInOrder().flatMap { sheet in
            sheet.json.dictionaryMap("texts")
                .sorted { $0.key < $1.key }
                .map { (sheet.id, $0.key, $0.value) }
        }
    }

    private func placeText(_ params: JSONDictionary) throws -> JSONDictionary {
        let existing = try params.string("id").map { reference -> (sheet: String, id: String, json: JSONDictionary) in
            guard let found = try sheetTexts().first(where: { $0.id.caseInsensitiveCompare(reference) == .orderedSame }) else {
                throw HorizontalDispatchError.notFound("No text \(reference) on any sheet. list_texts returns the ids.")
            }
            return found
        }
        // A text a symbol carries is the symbol's, extracted by Horizon's
        // Smash; it moves and dies with the symbol rather than on its own.
        if let existing, existing.json.bool("from_smash") == true {
            throw HorizontalDispatchError.invalidParams(
                "\(existing.id) is a symbol's own text, not free text on the sheet. Change the component instead."
            )
        }
        let targetSheet: String
        if params["sheet"] == nil, let existing {
            targetSheet = existing.sheet
        } else {
            targetSheet = try sheetID(params)
        }
        if let existing, existing.sheet != targetSheet {
            throw HorizontalDispatchError.invalidParams(
                "\(existing.id) is on another sheet. Remove it with remove_text, then write it on \(targetSheet)."
            )
        }

        var item = existing?.json ?? ["from_smash": false, "origin": "center", "font": "simplex", "width": 0, "size": 1_500_000]
        if let text = params.string("text") {
            guard !text.isEmpty else { throw HorizontalDispatchError.invalidParams("place_text needs a non-empty \"text\".") }
            item["text"] = text
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_text needs \"text\" for a text that is not on a sheet yet.")
        }
        for (key, allowed) in [("origin", Self.textOrigins), ("font", Self.textFonts)] {
            guard let value = params.string(key) else { continue }
            guard allowed.contains(value) else {
                throw HorizontalDispatchError.invalidParams("\(key) must be one of \(allowed.joined(separator: ", ")).")
            }
            item[key] = value
        }
        for (key, field) in [("size_mm", "size"), ("width_mm", "width")] {
            guard let millimetres = params.double(key) else { continue }
            guard millimetres >= 0 else { throw HorizontalDispatchError.invalidParams("\(key) cannot be negative.") }
            item[field] = Int((millimetres * 1_000_000).rounded())
        }
        guard (item["size"] as? Int ?? 0) > 0 else { throw HorizontalDispatchError.invalidParams("size_mm must be more than zero.") }

        var placement = item["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Int((x * 1_000_000).rounded()), Int((y * 1_000_000).rounded())]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_text needs \"x_mm\" and \"y_mm\" for a text that is not on a sheet yet.")
        }
        if let degrees = params.double("angle_deg") { placement["angle"] = Self.horizonAngle(degrees) }
        if let mirror = params.bool("mirror") { placement["mirror"] = mirror }
        item["placement"] = placement

        let id = existing?.id ?? UUID().uuidString.lowercased()
        try updateSheet(targetSheet) { sheet in
            var texts = sheet["texts"] as? JSONDictionary ?? [:]
            texts[id] = item
            sheet["texts"] = texts
        }
        return ["text_id": id, "sheet": targetSheet, "text": item.string("text") as Any, "created": existing == nil]
    }

    /// Free texts that sit by a component's symbols — within the radius, and
    /// nearer to one of them than to any other drawn symbol — on the sheets
    /// those symbols are drawn on.
    private func textsNear(componentID: String, gateID: String?, sheet only: String?, _ params: JSONDictionary) throws -> [(sheet: String, id: String)] {
        guard let radius = params.double("texts_within_mm") else { return [] }
        guard radius > 0 else { throw HorizontalDispatchError.invalidParams("texts_within_mm must be more than zero.") }
        var found = [(sheet: String, id: String)]()
        for page in try sheetsInOrder() where only == nil || only == page.id {
            let symbols = page.json.dictionaryMap("symbols")
            let mine = Set(symbols.filter {
                $0.value.string("component")?.lowercased() == componentID && (gateID == nil || $0.value.string("gate")?.lowercased() == gateID)
            }.keys)
            guard !mine.isEmpty else { continue }
            let owned = Set(symbols.values.flatMap { ($0["texts"] as? [String] ?? []).map { $0.lowercased() } })
            for (id, text) in page.json.dictionaryMap("texts") where text.bool("from_smash") != true && !owned.contains(id.lowercased()) {
                guard let near = HorizontalSchematicTextProximity.nearest(to: HorizontalSchematicTextProximity.position(of: text),
                                                                          symbols: symbols, pool: pool),
                      mine.contains(near.id), near.distance <= radius * 1_000_000 else { continue }
                found.append((page.id, id))
            }
        }
        return found
    }

    private func removeFreeTexts(_ texts: [(sheet: String, id: String)]) throws -> [String] {
        for (sheet, ids) in Dictionary(grouping: texts, by: \.sheet) {
            try updateSheet(sheet) { item in
                var map = item.dictionaryMap("texts")
                for text in ids { map.removeValue(forKey: text.id) }
                item["texts"] = map
            }
        }
        return texts.map(\.id).sorted()
    }

    private func removeText(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("id"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove_text needs \"id\"; list_texts returns them.")
        }
        let sheetFilter = params["sheet"] == nil ? nil : try sheetID(params)
        guard let found = try sheetTexts().first(where: {
            $0.id.caseInsensitiveCompare(reference) == .orderedSame && (sheetFilter == nil || $0.sheet == sheetFilter)
        }) else {
            throw HorizontalDispatchError.notFound("No text \(reference)\(sheetFilter == nil ? "" : " on that sheet").")
        }
        guard found.json.bool("from_smash") != true else {
            throw HorizontalDispatchError.invalidParams(
                "\(found.id) is a symbol's own text; removing the symbol is what removes it."
            )
        }
        // A text a symbol references would leave a dangling id behind.
        let referenced = try symbolInstances().contains { instance in
            (instance.json["texts"] as? [String] ?? []).contains { $0.caseInsensitiveCompare(found.id) == .orderedSame }
        }
        guard !referenced else {
            throw HorizontalDispatchError.invalidParams("\(found.id) belongs to a symbol on the sheet, which still refers to it.")
        }
        try updateSheet(found.sheet) { sheet in
            var texts = sheet["texts"] as? JSONDictionary ?? [:]
            texts.removeValue(forKey: found.id)
            sheet["texts"] = texts
        }
        return ["text_id": found.id, "sheet": found.sheet, "text": found.json.string("text") as Any]
    }

    // MARK: - Net labels, power symbols and sheets

    static let markOrientations = ["up", "down", "left", "right"]
    static let powerSymbolStyles = ["gnd", "dot", "antenna", "earth"]

    /// A junction on a schematic sheet, at a point, carrying a net. Net labels
    /// and power symbols both sit on one; a point that already has one joins it.
    private func ensureSheetJunction(_ sheetID: String, x: Double, y: Double, net: String?) throws -> String {
        let point = [Self.nanometres(x), Self.nanometres(y)]
        let sheets = try sheetsInOrder()
        let sheetJSON = sheets.first { $0.id == sheetID }?.json ?? [:]
        let existing = sheetJSON.dictionaryMap("junctions").first { $0.value["position"] as? [Int] == point }
        if let existing, let net {
            // A junction already at the point is reused — a net-less one takes
            // this net — but one on another live net would short the two.
            let connectivity = HorizontalSchematicNetConnectivity(sheet: sheetJSON, block: block)
            let known = Set(block.dictionaryMap("nets").keys.map { $0.lowercased() })
            let named = connectivity.namedNets(at: ["junc": existing.key]).intersection(known)
            guard named.isSubset(of: [net.lowercased()]) else {
                let names = named.map { block.dictionaryMap("nets")[$0]?.string("name") ?? $0 }.sorted()
                throw HorizontalDispatchError.invalidParams(
                    "The junction at (\(x), \(y)) is on \(names.joined(separator: ", ")); a mark for another net there would join them. Move it, or remove_junction first."
                )
            }
        }
        let id = existing?.key ?? UUID().uuidString.lowercased()
        try updateSheet(sheetID) { sheet in
            var junctions = sheet["junctions"] as? JSONDictionary ?? [:]
            var item = junctions[id] as? JSONDictionary ?? [:]
            item["position"] = point
            // A bus label's junction carries no net: the bus is not one net.
            if let net { item["net"] = net } else { item.removeValue(forKey: "net") }
            junctions[id] = item
            sheet["junctions"] = junctions
        }
        return id
    }

    /// The junctions a sheet's wires, marks and net ties stand on.
    private static func referencedJunctions(_ sheet: JSONDictionary) -> Set<String> {
        var referenced = Set<String>()
        for key in ["net_labels", "power_symbols", "bus_labels", "bus_rippers"] {
            for (_, item) in sheet.dictionaryMap(key) {
                if let junction = item.string("junction") { referenced.insert(junction.lowercased()) }
            }
        }
        for (_, tie) in sheet.dictionaryMap("net_ties") {
            for end in ["from", "to"] {
                if let junction = tie.string(end) { referenced.insert(junction.lowercased()) }
            }
        }
        for (_, line) in sheet.dictionaryMap("net_lines") {
            for end in ["from", "to"] {
                if let junction = line.dictionary(end)?.string("junc") { referenced.insert(junction.lowercased()) }
            }
        }
        return referenced
    }

    /// Junctions on a sheet that nothing refers to any more — only those
    /// among `candidates` when given, so a junction placed on purpose ahead of
    /// its wires is not swept up by an unrelated removal.
    @discardableResult
    private func collectSheetJunctions(_ sheetID: String, candidates: Set<String>? = nil) throws -> [String] {
        guard let sheet = try sheetsInOrder().first(where: { $0.id == sheetID })?.json else { return [] }
        let referenced = Self.referencedJunctions(sheet)
        let candidates = candidates.map { Set($0.map { $0.lowercased() }) }
        var removed = [String]()
        try updateSheet(sheetID) { sheet in
            var junctions = sheet["junctions"] as? JSONDictionary ?? [:]
            for id in junctions.keys where !referenced.contains(id.lowercased()) && (candidates?.contains(id.lowercased()) ?? true) {
                junctions.removeValue(forKey: id)
                removed.append(id)
            }
            sheet["junctions"] = junctions
        }
        return removed.sorted()
    }

    private func markOption(_ params: JSONDictionary, key: String, allowed: [String], default fallback: String) throws -> String {
        guard let value = params.string(key) else { return fallback }
        guard allowed.contains(value) else {
            throw HorizontalDispatchError.invalidParams("\(key) must be one of \(allowed.joined(separator: ", ")).")
        }
        return value
    }

    private func placePowerSymbol(_ params: JSONDictionary) throws -> JSONDictionary {
        let net = try netID(params)
        let sheetID = try sheetID(params)
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_power_symbol needs \"x_mm\" and \"y_mm\".")
        }
        let style = params.string("style")
        // Ground and earth hang down, dot and antenna stand up, as the app
        // places them; the style is the net's when this does not set one.
        let effectiveStyle = style ?? nets()[net]?.string("power_symbol_style")
        let orientation = try markOption(params, key: "orientation", allowed: Self.markOrientations,
                                         default: HorizontalSchematicSheet.defaultPowerSymbolOrientation(forStyle: effectiveStyle))
        if let style, !Self.powerSymbolStyles.contains(style) {
            throw HorizontalDispatchError.invalidParams("style must be one of \(Self.powerSymbolStyles.joined(separator: ", ")).")
        }
        // A power symbol on a net is what makes it a power net, and the symbol's
        // shape is a property of the net rather than of the symbol.
        var madePower = false
        try updateNet(net) { item in
            madePower = item.bool("is_power") != true
            item["is_power"] = true
            if let style { item["power_symbol_style"] = style }
        }
        let junction = try ensureSheetJunction(sheetID, x: x, y: y, net: net)
        let id = UUID().uuidString.lowercased()
        try updateSheet(sheetID) { sheet in
            var symbols = sheet["power_symbols"] as? JSONDictionary ?? [:]
            symbols[id] = ["junction": junction, "net": net, "orientation": orientation,
                           "mirror": params.bool("mirror") ?? false]
            sheet["power_symbols"] = symbols
        }
        var change: JSONDictionary = ["power_symbol": id, "net": net, "sheet": sheetID, "junction": junction]
        if madePower { change["note"] = "The net is now a power net, which is what a power symbol on it means." }
        if let style { change["style"] = style }
        return change
    }

    private func placeNetLabel(_ params: JSONDictionary) throws -> JSONDictionary {
        let net = try netID(params)
        let sheetID = try sheetID(params)
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_net_label needs \"x_mm\" and \"y_mm\".")
        }
        let orientation = try markOption(params, key: "orientation", allowed: Self.markOrientations, default: "right")
        let sizeMM = params.double("size_mm") ?? 1.5
        guard sizeMM > 0 else { throw HorizontalDispatchError.invalidParams("size_mm must be more than zero.") }
        let junction = try ensureSheetJunction(sheetID, x: x, y: y, net: net)
        let id = UUID().uuidString.lowercased()
        try updateSheet(sheetID) { sheet in
            var labels = sheet["net_labels"] as? JSONDictionary ?? [:]
            labels[id] = ["junction": junction, "last_net": net, "size": Self.nanometres(sizeMM),
                          "orientation": orientation, "offsheet_refs": params.bool("offsheet_refs") ?? true]
            sheet["net_labels"] = labels
        }
        return ["net_label": id, "net": net, "sheet": sheetID, "junction": junction,
                "orientation": orientation, "size_mm": sizeMM]
    }

    /// Removes one net label or power symbol, and the junction it leaves idle.
    private func removeSheetMark(_ params: JSONDictionary, key: String, label: String) throws -> JSONDictionary {
        guard let reference = params.string("id"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove needs \"id\".")
        }
        let found = try sheetsInOrder().compactMap { sheet -> (sheet: String, id: String)? in
            guard let match = sheet.json.dictionaryMap(key).keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
                return nil
            }
            return (sheet.id, match)
        }.first
        guard let found else {
            throw HorizontalDispatchError.notFound("No \(label) \(reference) on any sheet.")
        }
        try updateSheet(found.sheet) { sheet in
            var map = sheet[key] as? JSONDictionary ?? [:]
            map.removeValue(forKey: found.id)
            sheet[key] = map
        }
        return ["id": found.id, "sheet": found.sheet, "junctions_removed": try collectSheetJunctions(found.sheet)]
    }

    // MARK: - Block composition

    /// The blocks this project defines, other than the one being edited. A
    /// block cannot use itself.
    private func usableBlocks() -> [HorizontalProjectBlock] {
        project.blocks.filter { $0.uuid.lowercased() != blockID.lowercased() }
    }

    private func blockInstances() -> JSONDictionary {
        block["block_instances"] as? JSONDictionary ?? [:]
    }

    private func blockInstanceID(_ params: JSONDictionary, key: String = "instance") throws -> String {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required; list_block_instances returns them.")
        }
        let instances = blockInstances()
        if let match = instances.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let named = instances.filter { ($0.value as? JSONDictionary)?.string("refdes")?.caseInsensitiveCompare(reference) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("More than one block instance is called \(reference); use its id.",
                                                    candidates: named.keys.sorted())
        }
        guard let match = named.first else {
            throw HorizontalDispatchError.notFound("No block instance \(reference).")
        }
        return match.key
    }

    private func addBlockInstance(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("block"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_block_instance needs \"block\": the block to use.")
        }
        let candidates = usableBlocks().filter {
            $0.uuid.caseInsensitiveCompare(reference) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(reference) == .orderedSame
        }
        guard candidates.count == 1, let used = candidates.first else {
            if candidates.isEmpty {
                // Naming the block being edited is the mistake worth catching.
                if project.blocks.contains(where: { $0.uuid.caseInsensitiveCompare(reference) == .orderedSame }) {
                    throw HorizontalDispatchError.invalidParams("A block cannot use itself.")
                }
                throw HorizontalDispatchError.notFound(
                    "No block \(reference). Blocks this one can use: \(usableBlocks().map(\.displayName).joined(separator: ", "))."
                )
            }
            throw HorizontalDispatchError.ambiguous("More than one block is called \(reference); use its uuid.",
                                                    candidates: candidates.map(\.uuid))
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        var instances = blockInstances()
        guard instances[id] == nil else {
            throw HorizontalDispatchError.invalidParams("A block instance \(id) already exists.")
        }
        instances[id] = ["block": used.uuid, "refdes": params.string("refdes") ?? "U?",
                         "connections": [String: Any]()]
        block["block_instances"] = instances
        return ["block_instance": id, "block": used.uuid, "block_name": used.displayName,
                "refdes": params.string("refdes") ?? "U?",
                "note": "Its ports reach this block through connect_block_port, and place_block_symbol draws it."]
    }

    private func removeBlockInstance(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        var instances = blockInstances()
        instances.removeValue(forKey: id)
        block["block_instances"] = instances
        let symbols = try removeBlockSymbols(instanceID: id, sheetFilter: nil)
        return ["block_instance": id, "symbols": symbols]
    }

    /// A block's ports are the nets it declares as ports; a using block wires
    /// its own nets onto them.
    private func blockPortID(_ reference: String, of usedBlockID: String) throws -> String {
        guard let used = project.blocks.first(where: { $0.uuid.lowercased() == usedBlockID.lowercased() }),
              let filename = used.blockFilename,
              let data = try store.read(project.baseURL.appendingPathComponent(filename)),
              let json = try? JSONHelper.loadDictionary(from: data) else {
            throw HorizontalDispatchError.notFound("Could not read the used block to find its ports.")
        }
        let ports = json.dictionaryMap("nets").filter { $0.value.bool("is_port") == true }
        if let match = ports.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let named = ports.filter { $0.value.string("name")?.caseInsensitiveCompare(reference) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("More than one port is called \(reference); use its uuid.",
                                                    candidates: named.keys.sorted())
        }
        guard let match = named.first else {
            throw HorizontalDispatchError.notFound(
                "No port \(reference) on that block. Ports: \(ports.values.compactMap { $0.string("name") }.sorted().joined(separator: ", "))."
            )
        }
        return match.key
    }

    private func connectBlockPort(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        var instances = blockInstances()
        guard var instance = instances[id] as? JSONDictionary, let usedBlock = instance.string("block") else {
            throw HorizontalDispatchError.notFound("Block instance \(id) names no block.")
        }
        guard let portReference = params.string("port") else {
            throw HorizontalDispatchError.invalidParams("connect_block_port needs \"port\".")
        }
        let port = try blockPortID(portReference, of: usedBlock)
        let net: String
        if let existing = try? netID(params) {
            net = existing
        } else if params.bool("create_net") ?? false, let name = params.string("net") {
            net = try ensureNet(["name": name]).0
        } else {
            throw HorizontalDispatchError.notFound("No net matches \(params["net"] ?? "nothing"); pass create_net to make it.")
        }
        var connections = instance["connections"] as? JSONDictionary ?? [:]
        connections[port] = ["net": net]
        instance["connections"] = connections
        instances[id] = instance
        block["block_instances"] = instances
        return ["block_instance": id, "port": port, "net": net]
    }

    private func placeBlockSymbol(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        guard let instance = blockInstances()[id] as? JSONDictionary, let usedBlock = instance.string("block") else {
            throw HorizontalDispatchError.notFound("Block instance \(id) names no block.")
        }
        // A block draws itself with the symbol it defines; without one there is
        // nothing to put on the sheet.
        guard let used = project.blocks.first(where: { $0.uuid.lowercased() == usedBlock.lowercased() }),
              let symbolFilename = used.symbolFilename, !symbolFilename.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "The block \(usedBlock) defines no symbol of its own, so it cannot be drawn on a sheet. Give it one in Horizontal first."
            )
        }
        let existing = try blockSymbolInstances().first { $0.json.string("block_instance")?.lowercased() == id.lowercased() }
        let targetSheet: String
        if params["sheet"] == nil, let existing {
            targetSheet = existing.sheet
        } else {
            targetSheet = try sheetID(params)
        }
        if let existing, existing.sheet != targetSheet {
            throw HorizontalDispatchError.invalidParams(
                "\(existing.id) is already on another sheet. Remove it with remove_block_symbol, then place it on \(targetSheet)."
            )
        }
        var item = existing?.json ?? ["block_instance": id]
        var placement = item["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Self.nanometres(x), Self.nanometres(y)]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_block_symbol needs \"x_mm\" and \"y_mm\" the first time.")
        }
        if let degrees = params.double("angle_deg") { placement["angle"] = Self.horizonAngle(degrees) }
        if let mirror = params.bool("mirror") { placement["mirror"] = mirror }
        item["placement"] = placement
        let symbolID = existing?.id ?? UUID().uuidString.lowercased()
        try updateSheet(targetSheet) { sheet in
            var symbols = sheet["block_symbols"] as? JSONDictionary ?? [:]
            symbols[symbolID] = item
            sheet["block_symbols"] = symbols
        }
        return ["block_symbol": symbolID, "block_instance": id, "sheet": targetSheet, "created": existing == nil]
    }

    private func blockSymbolInstances() throws -> [(sheet: String, id: String, json: JSONDictionary)] {
        try sheetsInOrder().flatMap { sheet in
            sheet.json.dictionaryMap("block_symbols").sorted { $0.key < $1.key }.map { (sheet.id, $0.key, $0.value) }
        }
    }

    @discardableResult
    private func removeBlockSymbols(instanceID: String, sheetFilter: String?) throws -> Int {
        let doomed = try blockSymbolInstances().filter {
            $0.json.string("block_instance")?.lowercased() == instanceID.lowercased()
                && (sheetFilter == nil || $0.sheet == sheetFilter)
        }
        for symbol in doomed {
            try updateSheet(symbol.sheet) { sheet in
                var symbols = sheet["block_symbols"] as? JSONDictionary ?? [:]
                symbols.removeValue(forKey: symbol.id)
                sheet["block_symbols"] = symbols
            }
        }
        return doomed.count
    }

    private func removeBlockSymbol(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        let sheetFilter = params["sheet"] == nil ? nil : try sheetID(params)
        let removed = try removeBlockSymbols(instanceID: id, sheetFilter: sheetFilter)
        guard removed > 0 else {
            throw HorizontalDispatchError.notFound("No symbol for block instance \(id) is on a sheet.")
        }
        return ["block_instance": id, "symbols": removed]
    }

    // MARK: - Holes and keepouts

    /// Removes one entry from a board map, by id.
    private func removeBoardEntry(_ params: JSONDictionary, key: String, selector: String, label: String) throws -> JSONDictionary {
        guard let reference = params.string(selector), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(selector) is required; list_\(key) returns the ids.")
        }
        let map = try board()[key] as? JSONDictionary ?? [:]
        guard let id = map.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No \(label) \(reference) on the board.")
        }
        try updateBoard { board in
            var map = board[key] as? JSONDictionary ?? [:]
            map.removeValue(forKey: id)
            board[key] = map
        }
        return [selector: id]
    }

    private func placeHole(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_hole needs \"x_mm\" and \"y_mm\".")
        }
        // A board hole takes its shape from a padstack, the way Horizon's does.
        // Nothing here invents a diameter.
        guard let padstack = params.string("padstack")?.lowercased(), !padstack.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "place_hole needs \"padstack\": a hole padstack uuid. search_pool with kind padstack finds one, and import_pool_part brings it in."
            )
        }
        // A board hole is whatever its padstack drills. A padstack that defines
        // no hole yields no hole — the entry would be written, parse to
        // nothing, and be pruned by the app's next save without a word. Better
        // to refuse than to hand back an id for something that is not there.
        guard let definition = pool.padstack(padstack) else {
            throw HorizontalDispatchError.notFound(
                "No padstack \(padstack) in the project pool. import_pool_part or pool_write brings one in."
            )
        }
        guard !definition.dictionaryMap("holes").isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "The padstack \(definition.string("name") ?? padstack) defines no hole, so it would drill nothing. "
                    + "search_pool with kind padstack finds one whose padstack_type is hole or mechanical."
            )
        }
        var item: JSONDictionary = [
            "placement": ["shift": [Self.nanometres(x), Self.nanometres(y)],
                          "angle": Self.horizonAngle(params.double("angle_deg") ?? 0), "mirror": false],
            "padstack": padstack,
            "parameter_set": [String: Any]()
        ]
        // A hole on a net is plated and joins that net; one without is a
        // mounting hole. Horizon tells them apart by whether the net is there.
        if params.string("net") != nil {
            item["net"] = try netID(params)
        }
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var holes = board["holes"] as? JSONDictionary ?? [:]
            holes[id] = item
            board["holes"] = holes
        }
        return ["hole": id, "padstack": padstack, "net": item["net"] as Any? as Any,
                "x_mm": x, "y_mm": y]
    }

    private func placeKeepout(_ params: JSONDictionary) throws -> JSONDictionary {
        let vertices = try polygonVertices(params)
        let layer = params.int("layer")
        // A keepout's shape is a polygon like a plane's; the layer lives on the
        // polygon, and a keepout with none applies to all copper.
        let polygon = try writePolygon(layer: layer ?? HorizontalBoardLayers.topCopper, vertices: vertices)
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var keepouts = board["keepouts"] as? JSONDictionary ?? [:]
            keepouts[id] = ["polygon": polygon,
                            "keepout_class": params.string("keepout_class") ?? "",
                            "all_cu_layers": layer == nil,
                            "exposed_cu_only": params.bool("exposed_copper_only") ?? false,
                            "patch_types_cu": [String]()]
            board["keepouts"] = keepouts
        }
        return ["keepout": id, "polygon": polygon, "layer": layer as Any? as Any,
                "all_copper_layers": layer == nil]
    }

    private func removeKeepout(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("keepout"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove_keepout needs \"keepout\"; list_keepouts returns the ids.")
        }
        let keepouts = try board()["keepouts"] as? JSONDictionary ?? [:]
        guard let match = keepouts.first(where: { $0.key.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No keepout \(reference) on the board.")
        }
        let polygon = (match.value as? JSONDictionary)?.string("polygon")
        try updateBoard { board in
            var keepouts = board["keepouts"] as? JSONDictionary ?? [:]
            keepouts.removeValue(forKey: match.key)
            board["keepouts"] = keepouts
            if let polygon {
                var polygons = board["polygons"] as? JSONDictionary ?? [:]
                polygons.removeValue(forKey: polygon)
                board["polygons"] = polygons
            }
        }
        return ["keepout": match.key, "polygon": polygon as Any? as Any]
    }

    /// Moves a sheet to a page number, shifting the pages between up or down
    /// one, the way dragging a page in the app does. swap exchanges it with
    /// the page there instead. Either way no two sheets share a number.
    private func setSheetIndex(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try sheetID(params)
        guard let index = params.int("index") else {
            throw HorizontalDispatchError.invalidParams("set_sheet_index needs \"index\": the page number to give it.")
        }
        guard index > 0 else { throw HorizontalDispatchError.invalidParams("A page number starts at 1.") }
        let sheets = try sheetsInOrder()
        guard let current = sheets.first(where: { $0.id == id }) else {
            throw HorizontalDispatchError.notFound("No sheet \(id).")
        }
        let was = current.json.int("index") ?? 0
        let last = sheets.map { $0.json.int("index") ?? 0 }.max() ?? 0
        guard index <= last else { throw HorizontalDispatchError.invalidParams("The last page is \(last).") }
        guard was != index else { return ["sheet": id, "index": index, "was": was, "swapped_with": NSNull(), "moved": [String]()] }
        if params.bool("swap") ?? false {
            let occupant = sheets.first { $0.json.int("index") == index && $0.id != id }
            try updateSheet(id) { $0["index"] = index }
            if let occupant {
                try updateSheet(occupant.id) { $0["index"] = was }
            }
            return ["sheet": id, "index": index, "was": was, "swapped_with": occupant?.id as Any? as Any]
        }
        var moved = [String]()
        for other in sheets where other.id != id {
            guard let page = other.json.int("index") else { continue }
            if index < was, page >= index, page < was {
                try updateSheet(other.id) { $0["index"] = page + 1 }
                moved.append(other.id)
            } else if index > was, page <= index, page > was {
                try updateSheet(other.id) { $0["index"] = page - 1 }
                moved.append(other.id)
            }
        }
        try updateSheet(id) { $0["index"] = index }
        return ["sheet": id, "index": index, "was": was, "swapped_with": NSNull(), "moved": moved.sorted()]
    }

    // MARK: - Board text and dimensions

    private func placeBoardText(_ params: JSONDictionary) throws -> JSONDictionary {
        let texts = try board()["texts"] as? JSONDictionary ?? [:]
        let existing = try params.string("id").map { reference -> (id: String, json: JSONDictionary) in
            guard let key = texts.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }),
                  let item = texts[key] as? JSONDictionary else {
                throw HorizontalDispatchError.notFound("No board text \(reference). list_board_texts returns the ids.")
            }
            return (key, item)
        }
        // A text a package carries was extracted from it by Smash; it moves and
        // dies with the package rather than on its own.
        if let existing, existing.json.bool("from_smash") == true {
            throw HorizontalDispatchError.invalidParams(
                "\(existing.id) is a package's own text, not free text on the board. Change the component instead."
            )
        }
        var item = existing?.json ?? ["from_smash": false, "origin": "center", "font": "simplex",
                                      "width": 0, "size": 1_500_000]
        if let text = params.string("text") {
            guard !text.isEmpty else { throw HorizontalDispatchError.invalidParams("place_board_text needs a non-empty \"text\".") }
            item["text"] = text
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_board_text needs \"text\" for a text that is not on the board yet.")
        }
        if let layer = params.int("layer") {
            item["layer"] = layer
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_board_text needs \"layer\"; board_info lists them.")
        }
        for (key, allowed) in [("origin", Self.textOrigins), ("font", Self.textFonts)] {
            guard let value = params.string(key) else { continue }
            guard allowed.contains(value) else {
                throw HorizontalDispatchError.invalidParams("\(key) must be one of \(allowed.joined(separator: ", ")).")
            }
            item[key] = value
        }
        for (key, field) in [("size_mm", "size"), ("width_mm", "width")] {
            guard let millimetres = params.double(key) else { continue }
            guard millimetres >= 0 else { throw HorizontalDispatchError.invalidParams("\(key) cannot be negative.") }
            item[field] = Self.nanometres(millimetres)
        }
        guard (item["size"] as? Int ?? 0) > 0 else { throw HorizontalDispatchError.invalidParams("size_mm must be more than zero.") }

        var placement = item["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Self.nanometres(x), Self.nanometres(y)]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_board_text needs \"x_mm\" and \"y_mm\" the first time.")
        }
        if let degrees = params.double("angle_deg") { placement["angle"] = Self.horizonAngle(degrees) }
        if let mirror = params.bool("mirror") { placement["mirror"] = mirror }
        item["placement"] = placement

        let id = existing?.id ?? UUID().uuidString.lowercased()
        try updateBoard { board in
            var texts = board["texts"] as? JSONDictionary ?? [:]
            texts[id] = item
            board["texts"] = texts
        }
        return ["id": id, "text": item.string("text") as Any, "layer": item.int("layer") as Any? as Any,
                "created": existing == nil]
    }

    private func placeDimension(_ params: JSONDictionary) throws -> JSONDictionary {
        func point(_ key: String) throws -> [Int] {
            guard let value = params[key] as? JSONDictionary,
                  let x = value.double("x_mm"), let y = value.double("y_mm") else {
                throw HorizontalDispatchError.invalidParams("place_dimension needs \"\(key)\" as {\"x_mm\", \"y_mm\"}.")
            }
            let unknown = Set(value.keys).subtracting(["x_mm", "y_mm"])
            guard unknown.isEmpty else {
                throw HorizontalDispatchError.invalidParams("Unknown \(key) fields: \(unknown.sorted().joined(separator: ", ")).")
            }
            return [Self.nanometres(x), Self.nanometres(y)]
        }
        let p0 = try point("from"), p1 = try point("to")
        guard p0 != p1 else { throw HorizontalDispatchError.invalidParams("A dimension measures between two different points.") }
        let size = params.double("size_mm") ?? 1.5
        guard size > 0 else { throw HorizontalDispatchError.invalidParams("size_mm must be more than zero.") }
        let id = UUID().uuidString.lowercased()
        let mode = params.string("mode") ?? "distance"
        try updateBoard { board in
            var dimensions = board["dimensions"] as? JSONDictionary ?? [:]
            dimensions[id] = ["p0": p0, "p1": p1, "mode": mode,
                              "label_distance": Self.nanometres(params.double("label_distance_mm") ?? 1),
                              "label_size": Self.nanometres(size)]
            board["dimensions"] = dimensions
        }
        return ["dimension": id, "mode": mode,
                "from": ["x_mm": Double(p0[0]) / 1_000_000, "y_mm": Double(p0[1]) / 1_000_000],
                "to": ["x_mm": Double(p1[0]) / 1_000_000, "y_mm": Double(p1[1]) / 1_000_000]]
    }

    // MARK: - Buses and net ties

    private enum BusMark { case label, ripper }

    private func buses() -> JSONDictionary { block["buses"] as? JSONDictionary ?? [:] }

    private func busID(_ params: JSONDictionary, key: String = "bus") throws -> String {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required; list_buses returns them.")
        }
        let all = buses()
        if let match = all.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) { return match }
        let named = all.filter { ($0.value as? JSONDictionary)?.string("name")?.caseInsensitiveCompare(reference) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("More than one bus is called \(reference); use its id.",
                                                    candidates: named.keys.sorted())
        }
        guard let match = named.first else { throw HorizontalDispatchError.notFound("No bus \(reference).") }
        return match.key
    }

    private func addBus(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_bus needs a \"name\".")
        }
        var all = buses()
        if let existing = all.first(where: { ($0.value as? JSONDictionary)?.string("name") == name }) {
            return ["bus": existing.key, "name": name, "created": false]
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        guard all[id] == nil else { throw HorizontalDispatchError.invalidParams("A bus \(id) already exists.") }
        all[id] = ["name": name, "members": [String: Any]()]
        block["buses"] = all
        return ["bus": id, "name": name, "created": true,
                "note": "Empty until add_bus_member puts nets in it."]
    }

    private func removeBus(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try busID(params)
        var all = buses()
        all.removeValue(forKey: id)
        block["buses"] = all
        // Labels and rippers reference the bus; leaving them would point at
        // nothing.
        var marks = 0
        for sheet in try sheetsInOrder() {
            for key in ["bus_labels", "bus_rippers"] {
                let doomed = sheet.json.dictionaryMap(key).filter { $0.value.string("bus")?.lowercased() == id.lowercased() }
                guard !doomed.isEmpty else { continue }
                marks += doomed.count
                try updateSheet(sheet.id) { item in
                    var map = item[key] as? JSONDictionary ?? [:]
                    for id in doomed.keys { map.removeValue(forKey: id) }
                    item[key] = map
                }
            }
            try collectSheetJunctions(sheet.id)
        }
        return ["bus": id, "labels_and_rippers": marks]
    }

    private func addBusMember(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try busID(params)
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_bus_member needs a \"name\".")
        }
        let net = try netID(params)
        var all = buses()
        guard var bus = all[id] as? JSONDictionary else { throw HorizontalDispatchError.notFound("No bus \(id).") }
        var members = bus["members"] as? JSONDictionary ?? [:]
        if let existing = members.first(where: { ($0.value as? JSONDictionary)?.string("name") == name }) {
            var member = existing.value as? JSONDictionary ?? [:]
            member["net"] = net
            members[existing.key] = member
            bus["members"] = members
            all[id] = bus
            block["buses"] = all
            return ["bus": id, "member": existing.key, "name": name, "net": net, "created": false]
        }
        let memberID = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        members[memberID] = ["name": name, "net": net]
        bus["members"] = members
        all[id] = bus
        block["buses"] = all
        return ["bus": id, "member": memberID, "name": name, "net": net, "created": true]
    }

    private func busMemberID(_ reference: String, in busID: String) throws -> (id: String, net: String?) {
        guard let bus = buses()[busID] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound("No bus \(busID).")
        }
        let members = bus.dictionaryMap("members")
        if let match = members.first(where: { $0.key.caseInsensitiveCompare(reference) == .orderedSame }) {
            return (match.key, match.value.string("net")?.lowercased())
        }
        let named = members.filter { $0.value.string("name")?.caseInsensitiveCompare(reference) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("More than one member is called \(reference); use its id.",
                                                    candidates: named.keys.sorted())
        }
        guard let match = named.first else {
            throw HorizontalDispatchError.notFound(
                "No member \(reference) on that bus. Members: \(members.values.compactMap { $0.string("name") }.sorted().joined(separator: ", "))."
            )
        }
        return (match.key, match.value.string("net")?.lowercased())
    }

    private func placeBusMark(_ params: JSONDictionary, kind: BusMark) throws -> JSONDictionary {
        let bus = try busID(params)
        let sheetID = try sheetID(params)
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("A bus label or ripper needs \"x_mm\" and \"y_mm\".")
        }
        let defaultOrientation = kind == .label ? "right" : "up"
        let orientation = try markOption(params, key: "orientation", allowed: Self.markOrientations, default: defaultOrientation)
        var member: (id: String, net: String?)?
        if kind == .ripper {
            guard let reference = params.string("member") else {
                throw HorizontalDispatchError.invalidParams("place_bus_ripper needs \"member\": which net comes off the bus.")
            }
            member = try busMemberID(reference, in: bus)
        }
        // A ripper's junction carries the member's net, because that is what
        // comes off the bus there; a label's carries none.
        let junction = try ensureSheetJunction(sheetID, x: x, y: y, net: member?.net ?? nil)
        let id = UUID().uuidString.lowercased()
        let key = kind == .label ? "bus_labels" : "bus_rippers"
        try updateSheet(sheetID) { sheet in
            var map = sheet[key] as? JSONDictionary ?? [:]
            var item: JSONDictionary = ["junction": junction, "bus": bus, "orientation": orientation]
            if kind == .label {
                item["size"] = Self.nanometres(params.double("size_mm") ?? 1.5)
            } else if let member {
                item["bus_member"] = member.id
            }
            map[id] = item
            sheet[key] = map
        }
        var change: JSONDictionary = [kind == .label ? "bus_label" : "bus_ripper": id,
                                      "bus": bus, "sheet": sheetID, "junction": junction,
                                      "orientation": orientation]
        if let member {
            change["member"] = member.id
            change["net"] = member.net as Any? as Any
        }
        return change
    }

    private func netTies() -> JSONDictionary { block["net_ties"] as? JSONDictionary ?? [:] }

    private func addNetTie(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let primaryReference = params.string("primary"), let secondaryReference = params.string("secondary") else {
            throw HorizontalDispatchError.invalidParams("add_net_tie needs \"primary\" and \"secondary\".")
        }
        let primary = try netID(reference: primaryReference)
        let secondary = try netID(reference: secondaryReference)
        guard primary != secondary else {
            throw HorizontalDispatchError.invalidParams("A net tie joins two different nets.")
        }
        var all = netTies()
        if let existing = all.first(where: { item in
            guard let tie = item.value as? JSONDictionary else { return false }
            let ends = Set([tie.string("net_primary")?.lowercased(), tie.string("net_secondary")?.lowercased()].compactMap { $0 })
            return ends == Set([primary, secondary])
        }) {
            return ["net_tie": existing.key, "primary": primary, "secondary": secondary, "created": false]
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        guard all[id] == nil else { throw HorizontalDispatchError.invalidParams("A net tie \(id) already exists.") }
        all[id] = ["net_primary": primary, "net_secondary": secondary]
        block["net_ties"] = all
        return ["net_tie": id, "primary": primary, "secondary": secondary, "created": true,
                "note": "Joined on the board, kept apart in the schematic. place_net_tie draws it on a sheet."]
    }

    private func netTieID(_ params: JSONDictionary) throws -> String {
        guard let reference = params.string("net_tie"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("net_tie is required; list_net_ties returns them.")
        }
        guard let match = netTies().keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No net tie \(reference).")
        }
        return match
    }

    private func removeNetTie(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try netTieID(params)
        var all = netTies()
        all.removeValue(forKey: id)
        block["net_ties"] = all
        var symbols = 0
        for sheet in try sheetsInOrder() {
            let doomed = sheet.json.dictionaryMap("net_ties").filter { $0.value.string("net_tie")?.lowercased() == id.lowercased() }
            guard !doomed.isEmpty else { continue }
            symbols += doomed.count
            try updateSheet(sheet.id) { item in
                var map = item["net_ties"] as? JSONDictionary ?? [:]
                for key in doomed.keys { map.removeValue(forKey: key) }
                item["net_ties"] = map
            }
            try collectSheetJunctions(sheet.id)
        }
        return ["net_tie": id, "symbols": symbols]
    }

    private func placeNetTie(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try netTieID(params)
        let sheetID = try sheetID(params)
        guard let tie = netTies()[id] as? JSONDictionary,
              let primary = tie.string("net_primary")?.lowercased(),
              let secondary = tie.string("net_secondary")?.lowercased() else {
            throw HorizontalDispatchError.notFound("Net tie \(id) names no nets.")
        }
        func point(_ key: String) throws -> (x: Double, y: Double) {
            guard let value = params[key] as? JSONDictionary,
                  let x = value.double("x_mm"), let y = value.double("y_mm") else {
                throw HorizontalDispatchError.invalidParams("place_net_tie needs \"\(key)\" as {\"x_mm\", \"y_mm\"}.")
            }
            return (x, y)
        }
        let fromPoint = try point("from"), toPoint = try point("to")
        // Each end sits on its own net's junction: that is what keeps the two
        // nets apart on the sheet while the tie joins them on the board.
        let from = try ensureSheetJunction(sheetID, x: fromPoint.x, y: fromPoint.y, net: primary)
        let to = try ensureSheetJunction(sheetID, x: toPoint.x, y: toPoint.y, net: secondary)
        guard from != to else {
            throw HorizontalDispatchError.invalidParams("A net tie's two ends cannot be the same point.")
        }
        let symbolID = UUID().uuidString.lowercased()
        try updateSheet(sheetID) { sheet in
            var map = sheet["net_ties"] as? JSONDictionary ?? [:]
            map[symbolID] = ["net_tie": id, "from": from, "to": to]
            sheet["net_ties"] = map
        }
        return ["net_tie": id, "symbol": symbolID, "sheet": sheetID,
                "from": from, "to": to, "primary": primary, "secondary": secondary]
    }

    // MARK: - Board rules

    /// The context the app's own rules editor works in: the board's layers and
    /// the block's net classes.
    private func ruleContext() -> HorizontalBoardRuleContext {
        let netClasses = HorizontalDesignIndex.schematics(of: project).first(where: \.block.isTop)?.schematic.netClasses
            ?? project.schematic?.netClasses
            ?? []
        return HorizontalBoardRuleContext(board: project.board, netClasses: netClasses)
    }

    private func ruleKind(_ params: JSONDictionary) throws -> HorizontalBoardRuleKind {
        guard let raw = params.string("kind"), !raw.isEmpty else {
            throw HorizontalDispatchError.invalidParams("A rule needs a \"kind\"; board_rules lists them.")
        }
        guard let kind = HorizontalBoardRuleKind(rawValue: raw) else {
            throw HorizontalDispatchError.invalidParams(
                "Unknown rule kind \(raw). Known: \(HorizontalBoardRuleKind.visibleCases.map(\.rawValue).sorted().joined(separator: ", "))."
            )
        }
        return kind
    }

    /// Runs the app's own rules validator over a proposed rules object and
    /// refuses anything that would make the board's rules invalid.
    ///
    /// This is what makes writing rules safe enough to offer at all. A
    /// clearance rule written wrong is worse than no rule — it would let check
    /// pass on a board that should fail — so nothing is committed that the
    /// editor's own validator calls an error.
    private func validatedRules(_ rules: JSONDictionary) throws -> JSONDictionary {
        let context = ruleContext()
        var problems = [String]()
        for kind in HorizontalBoardRuleKind.visibleCases {
            for message in HorizontalBoardRulesValidator.validate(rules: rules, selectedKind: kind, context: context)
            where message.level == .error {
                problems.append("\(message.title): \(message.detail)")
            }
        }
        guard problems.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "That would leave the board's rules invalid, so nothing was written: \(Set(problems).sorted().joined(separator: "; "))"
            )
        }
        return rules
    }

    private func updateRules(_ body: (inout JSONDictionary) throws -> Void) throws {
        var rules = try board()["rules"] as? JSONDictionary ?? [:]
        try body(&rules)
        let checked = try validatedRules(rules)
        try updateBoard { $0["rules"] = checked }
    }

    /// One rule, addressed the way Horizon stores them: a kind that can hold
    /// several keys them by uuid, the rest hold the rule directly.
    private func ruleAddress(_ params: JSONDictionary, kind: HorizontalBoardRuleKind, mustExist: Bool) throws -> String? {
        guard kind.isMulti else {
            if params.string("id") != nil {
                throw HorizontalDispatchError.invalidParams("\(kind.rawValue) holds one rule, so it takes no \"id\".")
            }
            return nil
        }
        let family = (try board()["rules"] as? JSONDictionary ?? [:]).dictionary(kind.rawValue) ?? [:]
        guard let reference = params.string("id") else {
            guard !mustExist else {
                throw HorizontalDispatchError.invalidParams(
                    "\(kind.rawValue) can hold several rules, so it needs an \"id\". board_rules returns them."
                )
            }
            return UUID().uuidString.lowercased()
        }
        if let match = family.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        guard !mustExist else {
            throw HorizontalDispatchError.notFound("No \(kind.rawValue) rule \(reference).")
        }
        return reference.lowercased()
    }

    private func addRule(_ params: JSONDictionary) throws -> JSONDictionary {
        let kind = try ruleKind(params)
        let id = try ruleAddress(params, kind: kind, mustExist: false)
        var created: JSONDictionary = [:]
        try updateRules { rules in
            let existingCount = kind.isMulti ? (rules.dictionary(kind.rawValue)?.count ?? 0) : 0
            // The defaults the app's own rules editor would give it, so a rule
            // added here is the rule a person would have got.
            created = kind.defaultRule(context: ruleContext(), order: existingCount)
            if kind.isMulti {
                var family = rules.dictionary(kind.rawValue) ?? [:]
                guard let id else { return }
                guard family[id] == nil else {
                    throw HorizontalDispatchError.invalidParams("A \(kind.rawValue) rule \(id) already exists.")
                }
                family[id] = created
                rules[kind.rawValue] = family
            } else {
                guard rules[kind.rawValue] == nil else {
                    throw HorizontalDispatchError.invalidParams("\(kind.rawValue) already has its rule; set_rule changes it.")
                }
                rules[kind.rawValue] = created
            }
        }
        return ["kind": kind.rawValue, "rule_id": id as Any? as Any, "rule": created, "created": true]
    }

    private func setRule(_ params: JSONDictionary) throws -> JSONDictionary {
        let kind = try ruleKind(params)
        let id = try ruleAddress(params, kind: kind, mustExist: true)
        guard let fields = params["fields"] as? JSONDictionary, !fields.isEmpty else {
            throw HorizontalDispatchError.invalidParams("set_rule needs \"fields\": what to change.")
        }
        var merged: JSONDictionary = [:]
        try updateRules { rules in
            if kind.isMulti {
                var family = rules.dictionary(kind.rawValue) ?? [:]
                guard let id, var rule = family[id] as? JSONDictionary else {
                    throw HorizontalDispatchError.notFound("No \(kind.rawValue) rule to change.")
                }
                // Merged, not replaced: a caller changing one clearance should
                // not have to restate the rest of the rule to keep it.
                for (key, value) in fields { rule[key] = value }
                merged = rule
                family[id] = rule
                rules[kind.rawValue] = family
            } else {
                guard var rule = rules.dictionary(kind.rawValue) else {
                    throw HorizontalDispatchError.notFound("The board has no \(kind.rawValue) rule; add_rule makes one.")
                }
                for (key, value) in fields { rule[key] = value }
                merged = rule
                rules[kind.rawValue] = rule
            }
        }
        return ["kind": kind.rawValue, "rule_id": id as Any? as Any, "rule": merged,
                "changed": fields.keys.sorted()]
    }

    private func removeRule(_ params: JSONDictionary) throws -> JSONDictionary {
        let kind = try ruleKind(params)
        let id = try ruleAddress(params, kind: kind, mustExist: true)
        try updateRules { rules in
            if kind.isMulti, let id {
                var family = rules.dictionary(kind.rawValue) ?? [:]
                family.removeValue(forKey: id)
                if family.isEmpty { rules.removeValue(forKey: kind.rawValue) } else { rules[kind.rawValue] = family }
            } else {
                guard rules[kind.rawValue] != nil else {
                    throw HorizontalDispatchError.notFound("The board has no \(kind.rawValue) rule.")
                }
                rules.removeValue(forKey: kind.rawValue)
            }
        }
        return ["kind": kind.rawValue, "rule_id": id as Any? as Any, "removed": true]
    }

    // MARK: - Stackup

    private func setStackup(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let inner = params.int("inner_layers") else {
            throw HorizontalDispatchError.invalidParams("set_stackup needs \"inner_layers\".")
        }
        guard (0...30).contains(inner) else {
            throw HorizontalDispatchError.invalidParams("inner_layers must be between 0 and 30.")
        }
        let copper = Self.nanometres(params.double("copper_mm") ?? 0.035)
        guard copper > 0 else { throw HorizontalDispatchError.invalidParams("copper_mm must be above zero.") }
        let total = params.double("substrate_mm") ?? 1.6
        guard total > 0 else { throw HorizontalDispatchError.invalidParams("substrate_mm must be above zero.") }
        // Horizon's layers: 0 is top, -100 bottom, inner ones -1, -2, … Each
        // layer's substrate is the dielectric below it, so the bottom has none
        // and the cores share the total thickness between them.
        let cores = inner + 1
        let substrate = Self.nanometres(total / Double(cores))
        var stackup: JSONDictionary = ["0": ["thickness": copper, "substrate_thickness": substrate]]
        for layer in 1...max(inner, 1) where inner > 0 {
            stackup[String(-layer)] = ["thickness": copper, "substrate_thickness": substrate]
        }
        stackup["-100"] = ["thickness": copper, "substrate_thickness": 0]
        try updateBoard { board in
            board["n_inner_layers"] = inner
            board["stackup"] = stackup
        }
        return ["inner_layers": inner, "copper_layers": inner + 2, "copper_mm": Double(copper) / 1_000_000,
                "substrate_mm": Double(substrate) / 1_000_000,
                "note": "Copper layers are 0 (top), \(inner > 0 ? "-1…-\(inner) (inner), " : "")-100 (bottom)."]
    }

    // MARK: - Sheets

    /// The object maps a sheet carries. Mirrors the new-document template, so a
    /// sheet added here loads exactly like one the app made.
    private static let emptySheetKeys = ["junctions", "net_lines", "net_labels", "net_ties", "bus_labels",
                                         "bus_rippers", "power_symbols", "block_symbols", "symbols", "lines",
                                         "arcs", "texts", "pictures", "title_block_values"]

    private func addSheet(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_sheet needs a \"name\".")
        }
        let sheets = try sheetsInOrder()
        let last = (sheets.map { $0.json.int("index") ?? 0 }.max() ?? 0)
        let index = params.int("index") ?? (last + 1)
        guard index > 0 else { throw HorizontalDispatchError.invalidParams("A page number starts at 1.") }
        guard index <= last + 1 else {
            throw HorizontalDispatchError.invalidParams("There are \(sheets.count) sheets; a new one goes at page \(last + 1) or before.")
        }
        // The frame draws the title block. A new page looks like the others
        // unless told otherwise.
        let frame: String?
        switch params.string("frame") {
        case "none": frame = nil
        case let requested?:
            guard UUID(uuidString: requested) != nil else { throw HorizontalDispatchError.invalidParams("frame must be a pool frame uuid or \"none\".") }
            frame = requested.lowercased()
        case nil:
            frame = sheets.last?.json.string("frame")
        }
        let id = UUID().uuidString.lowercased()
        guard var schematic = files["schematic"] else {
            throw HorizontalDispatchError.notFound("The project has no schematic.")
        }
        var all = schematic["sheets"] as? JSONDictionary ?? [:]
        // A page already taken moves down, with every page after it.
        var shifted = [String]()
        for (sheetID, value) in all {
            guard var sheet = value as? JSONDictionary, let page = sheet.int("index"), page >= index else { continue }
            sheet["index"] = page + 1
            all[sheetID] = sheet
            shifted.append(sheetID)
        }
        var sheet: JSONDictionary = ["name": name, "index": index]
        for key in Self.emptySheetKeys { sheet[key] = [String: Any]() }
        if let frame { sheet["frame"] = frame }
        all[id] = sheet
        schematic["sheets"] = all
        files["schematic"] = schematic
        dirty.insert("schematic")
        var change: JSONDictionary = ["sheet": id, "name": name, "index": index, "frame": frame as Any? as Any]
        if !shifted.isEmpty { change["shifted"] = shifted.sorted() }
        return change
    }

    private func renameSheet(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try sheetID(params)
        guard let name = params.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HorizontalDispatchError.invalidParams("rename_sheet needs a \"name\".")
        }
        try updateSheet(id) { $0["name"] = name }
        return ["sheet": id, "name": name]
    }

    private func removeSheet(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try sheetID(params)
        let sheets = try sheetsInOrder()
        guard sheets.count > 1 else {
            throw HorizontalDispatchError.invalidParams("A schematic keeps at least one sheet.")
        }
        guard let sheet = sheets.first(where: { $0.id == id }) else {
            throw HorizontalDispatchError.notFound("No sheet \(id).")
        }
        // Deleting a page of work on the way to deleting a page is not a thing
        // to do quietly; clearing it is the caller's decision to make.
        let drawn = Self.emptySheetKeys
            .filter { $0 != "title_block_values" }
            .map { (key: $0, count: sheet.json.dictionaryMap($0).count) }
            .filter { $0.count > 0 }
        let force = params.bool("force") ?? false
        guard drawn.isEmpty || force else {
            throw HorizontalDispatchError.invalidParams(
                "Sheet \(sheet.json.string("name") ?? id) still holds \(drawn.map { "\($0.count) \($0.key)" }.joined(separator: ", ")). Clear it first, or pass force."
            )
        }
        guard var schematic = files["schematic"] else {
            throw HorizontalDispatchError.notFound("The project has no schematic.")
        }
        var all = schematic["sheets"] as? JSONDictionary ?? [:]
        all.removeValue(forKey: id)
        // The pages after it close up, so page numbers stay a sequence.
        let page = sheet.json.int("index") ?? 0
        for (sheetID, value) in all {
            guard var other = value as? JSONDictionary, let index = other.int("index"), index > page else { continue }
            other["index"] = index - 1
            all[sheetID] = other
        }
        schematic["sheets"] = all
        files["schematic"] = schematic
        dirty.insert("schematic")
        var change: JSONDictionary = ["sheet": id, "name": sheet.json.string("name") as Any]
        if !drawn.isEmpty {
            change["cleared"] = Dictionary(uniqueKeysWithValues: drawn.map { ($0.key, $0.count) })
            let unplaced = Set(sheet.json.dictionaryMap("symbols").values.compactMap { $0.string("component")?.lowercased() })
                .compactMap { components()[$0]?.string("refdes") }.sorted()
            if !unplaced.isEmpty {
                change["unplaced_components"] = unplaced
                change["note"] = "These components stay in the block with no symbol on any sheet; place_symbol draws them again."
            }
        }
        return change
    }

    /// Horizon's net-line endpoint: exactly one of the four is set.
    private static func pinEndpoint(_ path: String) -> JSONDictionary {
        ["bus_ripper": NSNull(), "junc": NSNull(), "pin": path, "port": NSNull()]
    }

    /// Horizon stores rotation as 1/65536 of a turn.
    private static func horizonAngle(_ degrees: Double) -> Int {
        var angle = Int((degrees / 360 * 65_536).rounded()) % 65_536
        if angle < 0 { angle += 65_536 }
        return angle
    }

    private func removeSchematicSymbols(componentID: String) -> Int {
        guard var schematic = files["schematic"] else {
            return 0
        }
        var removed = 0
        var sheets = schematic["sheets"] as? JSONDictionary ?? [:]
        for (sheetID, value) in sheets {
            guard var sheet = value as? JSONDictionary else {
                continue
            }
            var symbols = sheet["symbols"] as? JSONDictionary ?? [:]
            let doomed = symbols.filter { ($0.value as? JSONDictionary)?.string("component")?.lowercased() == componentID }
            guard !doomed.isEmpty else {
                continue
            }
            let doomedIDs = Set(doomed.keys.map { $0.lowercased() })
            var doomedTextIDs = Set<String>()
            for (id, symbol) in doomed {
                symbols.removeValue(forKey: id)
                for textID in (symbol as? JSONDictionary)?["texts"] as? [String] ?? [] {
                    doomedTextIDs.insert(textID.lowercased())
                }
            }
            removed += doomed.count
            sheet["symbols"] = symbols
            var lines = sheet["net_lines"] as? JSONDictionary ?? [:]
            lines = lines.filter { _, value in
                guard let line = value as? JSONDictionary else {
                    return true
                }
                for end in ["from", "to"] {
                    if let pin = line.dictionary(end)?.string("pin"), let symbolID = pin.split(separator: "/").first, doomedIDs.contains(String(symbolID).lowercased()) {
                        return false
                    }
                }
                return true
            }
            sheet["net_lines"] = lines
            if !doomedTextIDs.isEmpty {
                var texts = sheet["texts"] as? JSONDictionary ?? [:]
                texts = texts.filter { !doomedTextIDs.contains($0.key.lowercased()) }
                sheet["texts"] = texts
            }
            sheets[sheetID] = sheet
        }
        if removed > 0 {
            schematic["sheets"] = sheets
            files["schematic"] = schematic
            dirty.insert("schematic")
        }
        return removed
    }

    // MARK: - Board copper

    /// One end of a track, resolved to what the file will say and the net it
    /// already carries.
    private struct TrackEnd {
        var json: JSONDictionary
        var net: String?
        /// Set when this end needs a junction written for it.
        var newJunction: (id: String, point: [Int])?
    }

    private func board() throws -> JSONDictionary {
        guard isTopBlock else {
            throw HorizontalDispatchError.invalidParams(
                "The board belongs to the top block; a sub-block's components are instantiated wherever it is used, so there is no package to place for them. Edit the board without a \"block\"."
            )
        }
        guard let board = files["board"] else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        return board
    }

    private func updateBoard(_ body: (inout JSONDictionary) throws -> Void) throws {
        var board = try board()
        try body(&board)
        files["board"] = board
        dirty.insert("board")
    }

    private static func nanometres(_ millimetres: Double) -> Int {
        Int((millimetres * 1_000_000).rounded())
    }

    /// The pad uuid a name or uuid refers to on a component's package, and the
    /// net its pin is on.
    private func padOnComponent(_ reference: String, padReference: String) throws -> (package: String, pad: String, net: String?) {
        let componentID = try componentID(reference: reference)
        guard let component = components()[componentID] else {
            throw HorizontalDispatchError.notFound("No component \(reference).")
        }
        guard let partID = component.string("part")?.lowercased() else {
            throw HorizontalDispatchError.invalidParams("\(reference) has no part, so it has no pads.")
        }
        let packages = (try board()["packages"] as? JSONDictionary ?? [:])
        guard let placed = packages.first(where: { ($0.value as? JSONDictionary)?.string("component")?.lowercased() == componentID }) else {
            throw HorizontalDispatchError.notFound("\(reference) is not placed on the board; place_component it first.")
        }
        let terminals = pool.terminals(partID: partID)
        let matches = terminals.filter {
            ($0.string("id") ?? "").caseInsensitiveCompare(padReference) == .orderedSame
                || ($0.string("name") ?? "").caseInsensitiveCompare(padReference) == .orderedSame
        }
        guard matches.count == 1, let terminal = matches.first, let padID = terminal.string("id") else {
            if matches.isEmpty {
                throw HorizontalDispatchError.notFound(
                    "No pad \(padReference) on \(reference). Pads: \(terminals.compactMap { $0.string("name") }.sorted().joined(separator: ", "))."
                )
            }
            throw HorizontalDispatchError.ambiguous("More than one pad on \(reference) is called \(padReference); use its uuid.",
                                                    candidates: matches.compactMap { $0.string("id") })
        }
        // The pad's net is the net of the pin it maps to.
        let net = terminal.string("gate_pin_path").flatMap { path in
            (component["connections"] as? JSONDictionary)?.dictionary(path)?.string("net")?.lowercased()
        }
        return (placed.key, padID, net)
    }

    private func resolveTrackEnd(_ params: JSONDictionary, key: String) throws -> TrackEnd {
        guard let endpoint = params[key] as? JSONDictionary else {
            throw HorizontalDispatchError.invalidParams("place_track needs \"\(key)\".")
        }
        let known: Set<String> = ["component", "pad", "junction", "x_mm", "y_mm"]
        let unknown = Set(endpoint.keys).subtracting(known)
        guard unknown.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Unknown \(key) fields: \(unknown.sorted().joined(separator: ", ")).")
        }
        if let component = endpoint.string("component") {
            guard let pad = endpoint.string("pad") else {
                throw HorizontalDispatchError.invalidParams("\(key) names a component, so it needs a \"pad\" too.")
            }
            let resolved = try padOnComponent(component, padReference: pad)
            return TrackEnd(json: ["junc": NSNull(), "pad": "\(resolved.package)/\(resolved.pad)"], net: resolved.net)
        }
        if let junction = endpoint.string("junction")?.lowercased() {
            let junctions = try board()["junctions"] as? JSONDictionary ?? [:]
            guard let match = junctions.first(where: { $0.key.lowercased() == junction }) else {
                throw HorizontalDispatchError.notFound("No junction \(junction) on the board.")
            }
            return TrackEnd(json: ["junc": match.key, "pad": NSNull()],
                            net: (match.value as? JSONDictionary)?.string("net")?.lowercased())
        }
        guard let x = endpoint.double("x_mm"), let y = endpoint.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams(
                "\(key) must name a pad ({\"component\", \"pad\"}), a junction ({\"junction\"}) or a point ({\"x_mm\", \"y_mm\"})."
            )
        }
        let point = [Self.nanometres(x), Self.nanometres(y)]
        // A junction already at that exact point is the one to join, not a
        // second one on top of it.
        let junctions = try board()["junctions"] as? JSONDictionary ?? [:]
        if let existing = junctions.first(where: { ($0.value as? JSONDictionary)?["position"] as? [Int] == point }) {
            return TrackEnd(json: ["junc": existing.key, "pad": NSNull()],
                            net: (existing.value as? JSONDictionary)?.string("net")?.lowercased())
        }
        let id = UUID().uuidString.lowercased()
        return TrackEnd(json: ["junc": id, "pad": NSNull()], net: nil, newJunction: (id, point))
    }

    private func writeJunction(_ id: String, point: [Int], net: String?) throws {
        try updateBoard { board in
            var junctions = board["junctions"] as? JSONDictionary ?? [:]
            var item = junctions[id] as? JSONDictionary ?? [:]
            item["position"] = point
            if let net { item["net"] = net } else { item.removeValue(forKey: "net") }
            junctions[id] = item
            board["junctions"] = junctions
        }
    }

    private func placeTrack(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let layer = params.int("layer") else {
            throw HorizontalDispatchError.invalidParams("place_track needs \"layer\"; board_info lists the copper layers.")
        }
        if let given = params.double("width_mm"), given <= 0 {
            throw HorizontalDispatchError.invalidParams("width_mm must be above zero.")
        }
        let from = try resolveTrackEnd(params, key: "from")
        let to = try resolveTrackEnd(params, key: "to")
        var centre: [Int]?
        if let arc = params["arc_center"] as? JSONDictionary {
            guard let x = arc.double("x_mm"), let y = arc.double("y_mm") else {
                throw HorizontalDispatchError.invalidParams("arc_center needs \"x_mm\" and \"y_mm\".")
            }
            let unknown = Set(arc.keys).subtracting(["x_mm", "y_mm"])
            guard unknown.isEmpty else {
                throw HorizontalDispatchError.invalidParams("Unknown arc_center fields: \(unknown.sorted().joined(separator: ", ")).")
            }
            centre = [Self.nanometres(x), Self.nanometres(y)]
        }
        guard from.json["pad"] as? String != to.json["pad"] as? String || from.json["junc"] as? String != to.json["junc"] as? String else {
            throw HorizontalDispatchError.invalidParams("A track needs two different ends.")
        }

        // A track joins its ends, so ends on different nets would short them.
        // Refusing beats writing copper that quietly ties two nets together.
        let ends = [from.net, to.net].compactMap { $0 }
        if let first = ends.first, ends.contains(where: { $0 != first }) {
            let names = ends.map { nets()[$0]?.string("name") ?? $0 }
            throw HorizontalDispatchError.invalidParams(
                "The two ends are on different nets (\(names.joined(separator: ", "))); a track between them would short them."
            )
        }
        var carried = ends.first
        if let requested = params.string("net") {
            let resolved = try netID(reference: requested)
            if let carried, carried != resolved {
                throw HorizontalDispatchError.invalidParams(
                    "The ends are on \(nets()[carried]?.string("name") ?? carried), not \(requested)."
                )
            }
            carried = resolved
        }
        guard let net = carried else {
            throw HorizontalDispatchError.invalidParams("Neither end names a net, so pass \"net\".")
        }

        // A width the board's rules state for this net class on this layer is
        // not a guess; without one there is nothing to fall back on but a
        // number nobody chose, so the caller has to say.
        let ruled = ruledTrackWidth(net: net, layer: layer)
        guard let widthMM = params.double("width_mm") ?? ruled else {
            throw HorizontalDispatchError.invalidParams(
                "place_track needs \"width_mm\": this board states no track_width rule for that net class on layer \(layer). board_rules shows what it does state."
            )
        }
        for end in [from, to] {
            if let junction = end.newJunction {
                try writeJunction(junction.id, point: junction.point, net: net)
            }
        }
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var tracks = board["tracks"] as? JSONDictionary ?? [:]
            // Field set and defaults mirror Track::serialize, including pinning
            // width_from_net_class false so the width given here is the width used.
            var track: JSONDictionary = ["from": from.json, "to": to.json, "width": Self.nanometres(widthMM),
                                         "layer": layer, "width_from_net_class": false, "locked": false, "net": net]
            // A curved track keeps its centre as a coordinate, not a junction.
            if let centre { track["center"] = centre }
            tracks[id] = track
            board["tracks"] = tracks
        }
        var change: JSONDictionary = ["track": id, "net": net, "layer": layer, "width_mm": widthMM,
                                      "curved": centre != nil,
                                      "junctions_created": [from, to].compactMap { $0.newJunction?.id }]
        if params.double("width_mm") == nil { change["width_from"] = "track_width rule" }
        return change
    }

    /// The default width the board's `track_width` rules state for a net's
    /// class on a layer, in millimetres, or nil when they state none.
    private func ruledTrackWidth(net: String, layer: Int) -> Double? {
        guard let family = (try? board())?.dictionary("rules")?.dictionary("track_width") else { return nil }
        let netClass = nets()[net]?.string("net_class")?.lowercased()
        var best: Double?
        for (_, value) in family {
            guard let rule = value as? JSONDictionary, rule.bool("enabled") ?? true else { continue }
            let match = rule.dictionary("match")
            let mode = match?.string("mode") ?? "all"
            switch mode {
            case "all": break
            case "net_class":
                guard let netClass, match?.string("net_class")?.lowercased() == netClass else { continue }
            default: continue
            }
            guard let width = rule.dictionary("widths")?.dictionary(String(layer))?.double("def") else { continue }
            // A rule naming this net class beats one that matches everything.
            if mode == "net_class" { return width / 1_000_000 }
            best = best ?? width / 1_000_000
        }
        return best
    }

    /// Writes routed polylines as tracks, joining their bends with junctions.
    /// Used by `autoroute`, which has already had every path checked clear.
    /// Returns how many segments were written.
    func writeRoutedPaths(_ paths: [[HorizontalPoint]], net: String, layer: Int, widthMM: Double) throws -> Int {
        var written = 0
        for path in paths where path.count > 1 {
            var previous: JSONDictionary?
            for index in 1..<path.count {
                let a = path[index - 1], b = path[index]
                guard a != b else { continue }
                let from = try previous ?? endpointJSON(at: a, net: net)
                let to = try endpointJSON(at: b, net: net)
                let id = UUID().uuidString.lowercased()
                try updateBoard { board in
                    var tracks = board["tracks"] as? JSONDictionary ?? [:]
                    tracks[id] = ["from": from, "to": to, "width": Self.nanometres(widthMM),
                                  "layer": layer, "width_from_net_class": false, "locked": false, "net": net]
                    board["tracks"] = tracks
                }
                previous = to
                written += 1
            }
        }
        return written
    }

    /// A track end at a point: the pad whose centre it is, else a junction —
    /// reusing one already there so consecutive segments share their bend.
    private func endpointJSON(at point: HorizontalPoint, net: String) throws -> JSONDictionary {
        let key = [Int(point.x.rounded()), Int(point.y.rounded())]
        if let pad = project.board?.packagePadPositions.first(where: {
            Int($0.value.x.rounded()) == key[0] && Int($0.value.y.rounded()) == key[1]
        }) {
            return ["junc": NSNull(), "pad": pad.key]
        }
        let junctions = try board()["junctions"] as? JSONDictionary ?? [:]
        if let existing = junctions.first(where: { ($0.value as? JSONDictionary)?["position"] as? [Int] == key }) {
            return ["junc": existing.key, "pad": NSNull()]
        }
        let id = UUID().uuidString.lowercased()
        try writeJunction(id, point: key, net: net)
        return ["junc": id, "pad": NSNull()]
    }

    private func trackID(_ params: JSONDictionary, key: String = "track") throws -> String {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required; list_tracks returns the ids.")
        }
        let tracks = try board()["tracks"] as? JSONDictionary ?? [:]
        guard let match = tracks.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No track \(reference) on the board.")
        }
        return match
    }

    /// Drops junctions nothing refers to any more. Horizon has no free-standing
    /// junctions on a board; one exists to join copper.
    @discardableResult
    private func collectJunctions() throws -> [String] {
        var referenced = Set<String>()
        let board = try board()
        for (_, value) in board["tracks"] as? JSONDictionary ?? [:] {
            guard let track = value as? JSONDictionary else { continue }
            for end in ["from", "to"] {
                if let junction = track.dictionary(end)?.string("junc") { referenced.insert(junction.lowercased()) }
            }
        }
        for (_, value) in board["vias"] as? JSONDictionary ?? [:] {
            if let junction = (value as? JSONDictionary)?.string("junction") { referenced.insert(junction.lowercased()) }
        }
        var removed = [String]()
        try updateBoard { board in
            var junctions = board["junctions"] as? JSONDictionary ?? [:]
            for id in junctions.keys where !referenced.contains(id.lowercased()) {
                junctions.removeValue(forKey: id)
                removed.append(id)
            }
            board["junctions"] = junctions
        }
        return removed.sorted()
    }

    private func removeTrack(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try trackID(params)
        try updateBoard { board in
            var tracks = board["tracks"] as? JSONDictionary ?? [:]
            tracks.removeValue(forKey: id)
            board["tracks"] = tracks
        }
        return ["track": id, "junctions_removed": try collectJunctions()]
    }

    private func setTrackWidth(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try trackID(params)
        guard let widthMM = params.double("width_mm"), widthMM > 0 else {
            throw HorizontalDispatchError.invalidParams("set_track_width needs a \"width_mm\" above zero.")
        }
        try updateBoard { board in
            var tracks = board["tracks"] as? JSONDictionary ?? [:]
            var track = tracks[id] as? JSONDictionary ?? [:]
            track["width"] = Self.nanometres(widthMM)
            // The width given is the width used, not the net class's.
            track["width_from_net_class"] = false
            tracks[id] = track
            board["tracks"] = tracks
        }
        return ["track": id, "width_mm": widthMM]
    }

    private func placeVia(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_via needs \"x_mm\" and \"y_mm\".")
        }
        guard let reference = params.string("net") else {
            throw HorizontalDispatchError.invalidParams("place_via needs \"net\": a via carries one.")
        }
        let net = try netID(reference: reference)
        let padstack = params.string("padstack")?.lowercased() ?? project.board?.viaTemplate?.padstackID
        guard let padstack else {
            throw HorizontalDispatchError.invalidParams(
                "The board has no via to copy a padstack from, so pass \"padstack\" — a via padstack uuid from search_pool."
            )
        }
        let point = [Self.nanometres(x), Self.nanometres(y)]
        let junctions = try board()["junctions"] as? JSONDictionary ?? [:]
        let junction: String
        if let existing = junctions.first(where: { ($0.value as? JSONDictionary)?["position"] as? [Int] == point }) {
            junction = existing.key
        } else {
            junction = UUID().uuidString.lowercased()
        }
        try writeJunction(junction, point: point, net: net)
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var vias = board["vias"] as? JSONDictionary ?? [:]
            // net_set pins the net onto the via, so it seeds propagation like a
            // pad instead of waiting for copper to reach it.
            vias[id] = ["junction": junction, "padstack": padstack, "from_rules": true,
                        "net_set": net, "parameter_set": [String: Any]()]
            board["vias"] = vias
        }
        return ["via": id, "junction": junction, "net": net, "padstack": padstack]
    }

    private func removeVia(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("via"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove_via needs \"via\"; list_vias returns the ids.")
        }
        let vias = try board()["vias"] as? JSONDictionary ?? [:]
        guard let id = vias.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No via \(reference) on the board.")
        }
        try updateBoard { board in
            var vias = board["vias"] as? JSONDictionary ?? [:]
            vias.removeValue(forKey: id)
            board["vias"] = vias
        }
        return ["via": id, "junctions_removed": try collectJunctions()]
    }

    // MARK: - Board polygons and planes

    /// Horizon's polygon vertex: a straight corner unless an arc says otherwise.
    private func polygonVertices(_ params: JSONDictionary) throws -> [JSONDictionary] {
        guard let raw = params["vertices"] as? [Any] else {
            throw HorizontalDispatchError.invalidParams("vertices is required: three or more {\"x_mm\", \"y_mm\"} points.")
        }
        return try raw.enumerated().map { index, value in
            guard let point = value as? JSONDictionary, let x = point.double("x_mm"), let y = point.double("y_mm") else {
                throw HorizontalDispatchError.invalidParams("Vertex \(index) needs \"x_mm\" and \"y_mm\".")
            }
            let known: Set<String> = ["x_mm", "y_mm", "arc_center_x_mm", "arc_center_y_mm", "arc_reverse"]
            let unknown = Set(point.keys).subtracting(known)
            guard unknown.isEmpty else {
                throw HorizontalDispatchError.invalidParams("Unknown vertex fields: \(unknown.sorted().joined(separator: ", ")).")
            }
            // A vertex curves to the NEXT one around a centre. Horizon stores
            // the centre on the vertex the arc leaves, and both coordinates are
            // needed or the centre is meaningless.
            let centreX = point.double("arc_center_x_mm")
            let centreY = point.double("arc_center_y_mm")
            guard (centreX == nil) == (centreY == nil) else {
                throw HorizontalDispatchError.invalidParams(
                    "Vertex \(index) gives half an arc centre; an arc needs both arc_center_x_mm and arc_center_y_mm."
                )
            }
            if point["arc_reverse"] != nil, centreX == nil {
                throw HorizontalDispatchError.invalidParams("Vertex \(index) sets arc_reverse without an arc centre.")
            }
            let isArc = centreX != nil
            return ["type": isArc ? "arc" : "line",
                    "position": [Self.nanometres(x), Self.nanometres(y)],
                    "arc_center": [Self.nanometres(centreX ?? 0), Self.nanometres(centreY ?? 0)],
                    "arc_reverse": point.bool("arc_reverse") ?? false]
        }
    }

    /// Writes a polygon and returns its id. Field set mirrors Polygon::serialize.
    private func writePolygon(layer: Int, vertices: [JSONDictionary]) throws -> String {
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var polygons = board["polygons"] as? JSONDictionary ?? [:]
            polygons[id] = ["layer": layer, "parameter_class": "", "vertices": vertices]
            board["polygons"] = polygons
        }
        return id
    }

    private func placePolygon(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let layer = params.int("layer") else {
            throw HorizontalDispatchError.invalidParams("place_polygon needs \"layer\"; 100 is the board outline.")
        }
        let vertices = try polygonVertices(params)
        let id = try writePolygon(layer: layer, vertices: vertices)
        var change: JSONDictionary = ["polygon": id, "layer": layer, "vertices": vertices.count]
        if layer == 100 { change["note"] = "Layer 100 is the board outline; this is the shape the board is cut to." }
        return change
    }

    private func polygonID(_ params: JSONDictionary, key: String) throws -> String {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required.")
        }
        let polygons = try board()["polygons"] as? JSONDictionary ?? [:]
        guard let match = polygons.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No polygon \(reference) on the board.")
        }
        return match
    }

    private func removePolygon(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try polygonID(params, key: "polygon")
        // A plane's polygon is the plane's shape; removing it alone would leave
        // a plane pouring into nothing.
        let planes = try board()["planes"] as? JSONDictionary ?? [:]
        if let owner = planes.first(where: { ($0.value as? JSONDictionary)?.string("polygon")?.lowercased() == id.lowercased() }) {
            throw HorizontalDispatchError.invalidParams("Polygon \(id) is the shape of plane \(owner.key); remove_plane takes both.")
        }
        try updateBoard { board in
            var polygons = board["polygons"] as? JSONDictionary ?? [:]
            polygons.removeValue(forKey: id)
            board["polygons"] = polygons
        }
        return ["polygon": id]
    }

    private func placePlane(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let layer = params.int("layer") else {
            throw HorizontalDispatchError.invalidParams("place_plane needs a copper \"layer\".")
        }
        let net = try netID(params)
        let vertices = try polygonVertices(params)
        let polygon = try writePolygon(layer: layer, vertices: vertices)
        let id = UUID().uuidString.lowercased()
        try updateBoard { board in
            var planes = board["planes"] as? JSONDictionary ?? [:]
            // Field set mirrors Plane::serialize. from_rules true takes the pour
            // settings from the board rules, which is Horizon's default.
            planes[id] = ["net": net, "polygon": polygon, "priority": params.int("priority") ?? 0,
                          "from_rules": true, "settings": [String: Any]()]
            board["planes"] = planes
        }
        return ["plane": id, "polygon": polygon, "net": net, "layer": layer,
                "note": "Defined, not filled. pour_planes computes the copper."]
    }

    private func removePlane(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let reference = params.string("plane"), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("remove_plane needs \"plane\"; list_planes returns the ids.")
        }
        let planes = try board()["planes"] as? JSONDictionary ?? [:]
        guard let match = planes.first(where: { $0.key.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw HorizontalDispatchError.notFound("No plane \(reference) on the board.")
        }
        let polygon = (match.value as? JSONDictionary)?.string("polygon")
        try updateBoard { board in
            var planes = board["planes"] as? JSONDictionary ?? [:]
            planes.removeValue(forKey: match.key)
            board["planes"] = planes
            if let polygon {
                var polygons = board["polygons"] as? JSONDictionary ?? [:]
                polygons.removeValue(forKey: polygon)
                board["polygons"] = polygons
            }
        }
        return ["plane": match.key, "polygon": polygon as Any? as Any]
    }

    // MARK: - Board

    private func placeComponent(_ id: String, _ params: JSONDictionary) throws -> String {
        var board = try self.board()
        var packages = board["packages"] as? JSONDictionary ?? [:]
        let existing = packages.first { ($0.value as? JSONDictionary)?.string("component")?.lowercased() == id }
        var package = existing?.value as? JSONDictionary ?? [
            "component": id,
            "fixed": false,
            "flip": false,
            "omit_silkscreen": false,
            "smashed": false,
            "texts": [String]()
        ]
        var placement = package["placement"] as? JSONDictionary ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            placement["shift"] = [Int((x * 1_000_000).rounded()), Int((y * 1_000_000).rounded())]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_component needs \"x_mm\" and \"y_mm\" for a package that is not on the board yet.")
        }
        if let degrees = params.double("angle_deg") {
            var angle = Int((degrees / 360 * 65_536).rounded()) % 65_536
            if angle < 0 {
                angle += 65_536
            }
            placement["angle"] = angle
        }
        if let bottom = params.bool("bottom") {
            placement["mirror"] = bottom
            package["flip"] = bottom
        }
        package["placement"] = placement
        let packageID = existing?.key ?? UUID().uuidString.lowercased()
        packages[packageID] = package
        board["packages"] = packages
        files["board"] = board
        dirty.insert("board")
        return packageID
    }

    // MARK: - Group layout copy

    private func groupID(_ reference: String) throws -> String {
        let names = block["group_names"] as? [String: String] ?? [:]
        if let match = names.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
            return match
        }
        let byName = names.filter { $0.value == reference }
        if byName.count == 1, let match = byName.keys.first {
            return match
        }
        if byName.count > 1 {
            throw HorizontalDispatchError.invalidParams("\(byName.count) groups are named \(reference); use the id.")
        }
        throw HorizontalDispatchError.notFound("No group \(reference). Known: \(names.values.sorted().joined(separator: ", ")).")
    }

    private struct GroupMember {
        var componentID: String
        var tagID: String
        var partID: String?
        var packageID: String?
        var placement: JSONDictionary?
        var flip: Bool
    }

    private func members(ofGroup groupID: String) -> [String: GroupMember] {
        let packages = (files["board"] ?? [:]).dictionaryMap("packages")
        var result = [String: GroupMember]()
        for (componentID, component) in components() where component.string("group")?.lowercased() == groupID.lowercased() {
            let tagID = component.string("tag")?.lowercased() ?? Self.nullUUID
            guard tagID != Self.nullUUID else {
                continue
            }
            let package = packages.first { ($0.value.string("component") ?? "").lowercased() == componentID.lowercased() }
            result[tagID] = GroupMember(
                componentID: componentID,
                tagID: tagID,
                partID: component.string("part")?.lowercased(),
                packageID: package?.key,
                placement: package?.value.dictionary("placement"),
                flip: package?.value.bool("flip") ?? false
            )
        }
        return result
    }

    private static func rotate(_ x: Double, _ y: Double, angle: Int) -> (Double, Double) {
        let radians = Double(angle) / 65_536 * 2 * Double.pi
        return (x * cos(radians) - y * sin(radians), x * sin(radians) + y * cos(radians))
    }

    private static func shift(_ placement: JSONDictionary?) -> (Double, Double) {
        guard let shift = placement?["shift"] as? [Any], shift.count == 2 else {
            return (0, 0)
        }
        return (JSONHelper.doubleValue(shift[0]), JSONHelper.doubleValue(shift[1]))
    }

    private func copyGroupLayout(_ params: JSONDictionary) throws -> JSONDictionary {
        _ = try board()
        guard let sourceReference = params.string("source"), let targetReference = params.string("target") else {
            throw HorizontalDispatchError.invalidParams("copy_group_layout needs \"source\" and \"target\".")
        }
        let sourceID = try groupID(sourceReference)
        let targetID = try groupID(targetReference)
        guard sourceID.lowercased() != targetID.lowercased() else {
            throw HorizontalDispatchError.invalidParams("Source and target are the same group.")
        }
        let source = members(ofGroup: sourceID)
        let target = members(ofGroup: targetID)
        let tagNames = block["tag_names"] as? [String: String] ?? [:]
        let shared = source.keys.filter { target[$0] != nil && source[$0]?.placement != nil }
            .sorted { (tagNames[$0] ?? $0).localizedStandardCompare(tagNames[$1] ?? $1) == .orderedAscending }
        guard let anchorTag = shared.first, let sourceAnchor = source[anchorTag], let targetAnchor = target[anchorTag] else {
            throw HorizontalDispatchError.notFound("The groups share no placed member with a common tag.")
        }

        // Where the copy goes: the target anchor's own placement, an explicit
        // position, or beside the source.
        let (sourceAnchorX, sourceAnchorY) = Self.shift(sourceAnchor.placement)
        let sourceAnchorAngle = sourceAnchor.placement?.int("angle") ?? 0
        var targetX: Double
        var targetY: Double
        var targetAngle: Int
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            targetX = (x * 1_000_000).rounded()
            targetY = (y * 1_000_000).rounded()
            targetAngle = params.double("angle_deg").map { Int(($0 / 360 * 65_536).rounded()) % 65_536 } ?? sourceAnchorAngle
        } else if let placement = targetAnchor.placement {
            (targetX, targetY) = Self.shift(placement)
            targetAngle = params.double("angle_deg").map { Int(($0 / 360 * 65_536).rounded()) % 65_536 } ?? (placement.int("angle") ?? sourceAnchorAngle)
        } else {
            let xs = source.values.compactMap { $0.placement.map { Self.shift($0).0 } }
            let width = (xs.max() ?? sourceAnchorX) - (xs.min() ?? sourceAnchorX)
            targetX = sourceAnchorX + width + 5_000_000
            targetY = sourceAnchorY
            targetAngle = sourceAnchorAngle
        }
        if targetAngle < 0 {
            targetAngle += 65_536
        }
        let deltaAngle = (targetAngle - sourceAnchorAngle + 65_536) % 65_536
        let flip = targetAnchor.placement != nil ? targetAnchor.flip : sourceAnchor.flip
        let mirrorX = flip != sourceAnchor.flip

        var board = files["board"]!
        var packages = board["packages"] as? JSONDictionary ?? [:]
        var packageMap = [String: String]()   // source board package id -> target board package id
        var placed = 0
        for tag in shared {
            guard let member = source[tag], let placement = member.placement, let counterpart = target[tag] else {
                continue
            }
            let (x, y) = Self.shift(placement)
            var (dx, dy) = (x - sourceAnchorX, y - sourceAnchorY)
            var angle = placement.int("angle") ?? 0
            if mirrorX {
                dx = -dx
                angle = (65_536 - angle) % 65_536
            }
            let (rx, ry) = Self.rotate(dx, dy, angle: mirrorX ? (65_536 - deltaAngle) % 65_536 : deltaAngle)
            let newAngle = mirrorX
                ? ((angle - sourceAnchorAngle + targetAngle) % 65_536 + 65_536) % 65_536
                : (angle + deltaAngle) % 65_536
            let targetPackageID = counterpart.packageID ?? UUID().uuidString.lowercased()
            var package = packages[targetPackageID] as? JSONDictionary ?? [
                "component": counterpart.componentID,
                "fixed": false,
                "omit_silkscreen": false,
                "smashed": false,
                "texts": [String]()
            ]
            package["flip"] = flip
            package["placement"] = [
                "angle": newAngle,
                "mirror": flip,
                "shift": [Int((targetX + rx).rounded()), Int((targetY + ry).rounded())]
            ]
            packages[targetPackageID] = package
            if let sourcePackageID = member.packageID, member.partID == counterpart.partID {
                packageMap[sourcePackageID.lowercased()] = targetPackageID
            }
            placed += 1
        }
        board["packages"] = packages

        var copiedTracks = 0
        var copiedVias = 0
        var copiedJunctions = 0
        if params.bool("include_routing") ?? true {
            let transform: (Double, Double) -> (Int, Int) = { x, y in
                var dx = x - sourceAnchorX
                let dy = y - sourceAnchorY
                if mirrorX {
                    dx = -dx
                }
                let (rx, ry) = Self.rotate(dx, dy, angle: mirrorX ? (65_536 - deltaAngle) % 65_536 : deltaAngle)
                return (Int((targetX + rx).rounded()), Int((targetY + ry).rounded()))
            }
            let mapLayer: (Int) -> Int = { layer in
                guard mirrorX else {
                    return layer
                }
                if layer == 0 {
                    return -100
                }
                if layer == -100 {
                    return 0
                }
                return layer
            }
            var tracks = board["tracks"] as? JSONDictionary ?? [:]
            var junctions = board["junctions"] as? JSONDictionary ?? [:]
            var vias = board["vias"] as? JSONDictionary ?? [:]
            let sourcePackageIDs = Set(packageMap.keys)

            func padPackage(_ endpoint: JSONDictionary?) -> String? {
                guard let pad = endpoint?.string("pad") else {
                    return nil
                }
                return pad.split(separator: "/").first.map { String($0).lowercased() }
            }
            // The group's routing: tracks on its pads, and every track and
            // via reachable from those through junctions, as long as no end
            // touches a pad outside the group.
            var groupJunctions = Set<String>()
            var groupTracks = Set<String>()
            var frontier = true
            while frontier {
                frontier = false
                for (trackID, value) in tracks where !groupTracks.contains(trackID) {
                    guard let track = value as? JSONDictionary else {
                        continue
                    }
                    let ends = [track.dictionary("from"), track.dictionary("to")]
                    var touchesGroup = false
                    var leavesGroup = false
                    for end in ends {
                        if let package = padPackage(end) {
                            if sourcePackageIDs.contains(package) {
                                touchesGroup = true
                            } else {
                                leavesGroup = true
                            }
                        } else if let junction = end?.string("junc")?.lowercased(), groupJunctions.contains(junction) {
                            touchesGroup = true
                        }
                    }
                    guard touchesGroup, !leavesGroup else {
                        continue
                    }
                    groupTracks.insert(trackID)
                    frontier = true
                    for end in ends {
                        if let junction = end?.string("junc")?.lowercased() {
                            groupJunctions.insert(junction)
                        }
                    }
                }
            }
            var junctionMap = [String: String]()
            for junctionID in groupJunctions {
                guard let junction = junctions.first(where: { $0.key.lowercased() == junctionID })?.value as? JSONDictionary else {
                    continue
                }
                let (x, y) = Self.shift(["shift": junction["position"] as Any])
                let (nx, ny) = transform(x, y)
                let newID = UUID().uuidString.lowercased()
                junctions[newID] = ["position": [nx, ny]]
                junctionMap[junctionID] = newID
                copiedJunctions += 1
            }
            for trackID in groupTracks {
                guard var track = tracks[trackID] as? JSONDictionary else {
                    continue
                }
                var valid = true
                for end in ["from", "to"] {
                    guard var endpoint = track.dictionary(end) else {
                        valid = false
                        break
                    }
                    if let pad = endpoint.string("pad") {
                        let pieces = pad.split(separator: "/", maxSplits: 1).map(String.init)
                        guard pieces.count == 2, let mapped = packageMap[pieces[0].lowercased()] else {
                            valid = false
                            break
                        }
                        endpoint["pad"] = "\(mapped)/\(pieces[1])"
                        endpoint["junc"] = NSNull()
                    } else if let junction = endpoint.string("junc")?.lowercased(), let mapped = junctionMap[junction] {
                        endpoint["junc"] = mapped
                    } else {
                        valid = false
                        break
                    }
                    track[end] = endpoint
                }
                guard valid else {
                    continue
                }
                if let layer = track.int("layer") {
                    track["layer"] = mapLayer(layer)
                }
                tracks[UUID().uuidString.lowercased()] = track
                copiedTracks += 1
            }
            for (_, value) in vias {
                guard var via = value as? JSONDictionary, let junction = via.string("junction")?.lowercased(), let mapped = junctionMap[junction] else {
                    continue
                }
                via["junction"] = mapped
                via.removeValue(forKey: "net_set")
                vias[UUID().uuidString.lowercased()] = via
                copiedVias += 1
            }
            board["tracks"] = tracks
            board["junctions"] = junctions
            board["vias"] = vias
        }
        files["board"] = board
        dirty.insert("board")
        return [
            "source": sourceID,
            "target": targetID,
            "anchor_tag": tagNames[anchorTag] ?? anchorTag,
            "placed": placed,
            "tracks": copiedTracks,
            "vias": copiedVias,
            "junctions": copiedJunctions,
            "mirrored": mirrorX
        ]
    }

    /// Removes the board packages of a component. Tracks that ended on one of
    /// its pads keep their copper: the pad end becomes a junction at the pad's
    /// position, the way Horizon's delete leaves a track when its pad goes.
    private func removeBoardPackages(componentID: String) -> Int {
        guard var board = files["board"] else {
            return 0
        }
        var packages = board["packages"] as? JSONDictionary ?? [:]
        let doomed = packages.filter { ($0.value as? JSONDictionary)?.string("component")?.lowercased() == componentID }
        guard !doomed.isEmpty else {
            return 0
        }
        let doomedIDs = Set(doomed.keys.map { $0.lowercased() })
        var doomedTextIDs = Set<String>()
        for (id, package) in doomed {
            packages.removeValue(forKey: id)
            for textID in (package as? JSONDictionary)?["texts"] as? [String] ?? [] {
                doomedTextIDs.insert(textID.lowercased())
            }
        }
        board["packages"] = packages

        var junctions = board["junctions"] as? JSONDictionary ?? [:]
        var tracks = board["tracks"] as? JSONDictionary ?? [:]
        let padPositions = project.board?.packagePadPositions ?? [:]
        for (trackID, value) in tracks {
            guard var track = value as? JSONDictionary else {
                continue
            }
            var changed = false
            var drop = false
            for end in ["from", "to"] {
                guard var endpoint = track.dictionary(end), let pad = endpoint.string("pad") else {
                    continue
                }
                let pieces = pad.split(separator: "/", maxSplits: 1).map { String($0).lowercased() }
                guard pieces.count == 2, doomedIDs.contains(pieces[0]) else {
                    continue
                }
                guard let position = padPositions[pad.lowercased()] ?? padPositions["\(pieces[0])/\(pieces[1])"] else {
                    drop = true
                    break
                }
                let junctionID = UUID().uuidString.lowercased()
                junctions[junctionID] = ["position": [Int(position.x.rounded()), Int(position.y.rounded())]]
                endpoint["pad"] = NSNull()
                endpoint["junc"] = junctionID
                track[end] = endpoint
                changed = true
            }
            if drop {
                tracks.removeValue(forKey: trackID)
            } else if changed {
                tracks[trackID] = track
            }
        }
        board["tracks"] = tracks
        board["junctions"] = junctions
        if !doomedTextIDs.isEmpty {
            var texts = board["texts"] as? JSONDictionary ?? [:]
            texts = texts.filter { !doomedTextIDs.contains($0.key.lowercased()) }
            board["texts"] = texts
        }
        files["board"] = board
        dirty.insert("board")
        return doomed.count
    }
}
