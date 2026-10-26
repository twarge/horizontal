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
    case moveSymbols = "move_symbols"
    case moveToOtherSheet = "move_to_other_sheet"
    case removeSymbol = "remove_symbol"
    case drawNetLine = "draw_net_line"
    case placeJunction = "place_junction"
    case setNetLineEndpoint = "set_net_line_endpoint"
    case removeNetLine = "remove_net_line"
    case removeJunction = "remove_junction"
    case pruneSheet = "prune_sheet"
    case terminatePin = "terminate_pin"
    case setSymbolDisplay = "set_symbol_display"
    case setCustomValue = "set_custom_value"
    case smash = "smash"
    case unsmash = "unsmash"
    case setNoConnect = "set_no_connect"
    case setPinAlternate = "set_pin_alternate"
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
    case disconnectBlockPort = "disconnect_block_port"
    case setBlockInstance = "set_block_instance"
    case addBlock = "add_block"
    case renameBlock = "rename_block"
    case removeBlock = "remove_block"
    case setNetPort = "set_net_port"
    case placeBlockPort = "place_block_port"
    case removeBlockPort = "remove_block_port"
    case annotate = "annotate"
    case setStackup = "set_stackup"
    case addRule = "add_rule"
    case setRule = "set_rule"
    case removeRule = "remove_rule"
    case addSheet = "add_sheet"
    case renameSheet = "rename_sheet"
    case setSheetFrame = "set_sheet_frame"
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
    case setProjectMeta = "set_project_meta"
    case setExportSettings = "set_export_settings"

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
        case .removeComponent: "Remove a component, its symbols, its board package, and the copper attached to it. The wiring that served only it goes too — wires that reach no pin once it is gone, with their labels and power symbols, and dead ends that ran to it — unless keep_wiring."
        case .setValue: "Set a component's value. A part's own value is the one shown, and the apply_ops reply gives warnings when it hides the value set."
        case .setRefdes: "Set a component's reference designator."
        case .setPart: "Assign a pool part (and its entity) to a component; null clears the part."
        case .setNoPopulate: "Mark a component do-not-populate or not."
        case .setGroupTag: "Set the group and tag names Horizon uses to copy placement between identical sub-circuits."
        case .ensureNet: "Create a net if no net has that id or name; returns its id. An empty name always makes a new net with no name."
        case .addBus: "Create a bus — a named bundle the nets in it travel as one line on a sheet."
        case .removeBus: "Remove a bus, its members, and the labels and rippers drawn for it."
        case .addBusMember: "Put a net in a bus under a member name."
        case .placeBusLabel: "Label a bus on a sheet, the way a net label names a net. id naming a bus label that is there changes its orientation, size or place."
        case .placeBusRipper: "Take one member off a bus at a point, so it can be wired on its own."
        case .addNetTie: "Tie two nets together — joined on the board, kept apart in the schematic, which is what a tie is for."
        case .removeNetTie: "Remove a net tie and the symbols drawn for it."
        case .placeNetTie: "Draw a net tie on a sheet, between a point on each of its two nets."
        case .addNetClass: "Create a net class. Its electrical parameters live in the board rules; board_rules shows them."
        case .renameNetClass: "Rename a net class."
        case .renameNet: "Rename a net."
        case .setNetClass: "Put a net in a net class, by name or id."
        case .retireNet: "Remove a net, every connection to it, and the labels, power symbols, wires and junctions drawn for it. Its planes go too, since a plane needs a net; their outlines stay as polygons. Tracks and vias on it are reported, or removed with remove_routing."
        case .connect: "Connect a component pin to a net."
        case .disconnect: "Remove a pin's connection."
        case .placeSymbol: "Draw a component's gate on a schematic sheet, or move it if it is already drawn. A component connected without this is in the netlist but on no sheet."
        case .moveToOtherSheet: "Horizon's Move to other sheet: the items and everything drawn connected to them go to another sheet whole, at the same place unless dx_mm/dy_mm, and nothing is cut. A wire brings the junctions, symbols and ports at its ends, a symbol its texts and wires, a junction its wires, labels, power symbols and the graphic lines and arcs on it, until nothing more is reached. move_symbols with to_sheet moves symbols alone, cutting the wiring they share."
        case .moveSymbols: "Move symbols by an offset, or onto another sheet, with the wiring that belongs only to them: the junctions of the stubs and islands that serve no other part, and the wires, net labels and power symbols on those junctions. A wire to wiring that stays stretches to it; moving to another sheet cuts it instead, and the reply names each cut end with its net, for a label there. place_symbol moves one symbol alone."
        case .setSymbolDisplay: "Change how a drawn symbol shows its pins: which pin names (pin_display_mode) and whether a multi-pad pin lists every pad number (display_all_pads). The apply_ops reply gives warnings when custom_only hides alternates the symbol's pins have chosen."
        case .setCustomValue: "Give a drawn symbol a custom value: text that its $VALUE text draws instead of the value, with ${value}, ${mpn}, ${mfr}, ${desc}, ${pkg} and ${p:<parametric column>} filled in from the component and its part, as Horizon's Edit Custom Value does — \"${value}\\n${mpn}\" shows the value over the MPN. \"\" or null clears it. get_component gives each symbol's custom_value and drawn_value."
        case .smash: "Horizon's Smash: a drawn symbol's texts — its refdes and value — become texts of its sheet that it owns, where it drew them, so place_text moves each on its own while they go on drawing what the component says. With board, the same for the silkscreen texts of its package on the board, which place_board_text moves. A symbol smashed already keeps its texts, and one whose texts are all gone is smashed afresh. The reply names the texts made."
        case .unsmash: "Horizon's Unsmash: delete the texts a smash gave a component's symbols (with board, its package), so they draw their own again. A symbol smashed with its texts gone, which draws no refdes or value, is put right this way too."
        case .removeSymbol: "Take a component's gate off its sheet, as the app's delete and Horizon's do: the wires that ended on its pins end on junctions where the pins were, and its pins leave their nets and no-connect marks (removed.disconnected names them), so the gate placed again starts unconnected. The wiring that leaves serving nothing — what find_dangling would call new debris — goes too, unless keep_wiring. The component stays for its other gates."
        case .drawNetLine: "Draw a wire between pins, block ports or junctions on one logical net. Does not change block connectivity, except as Horizon's wire tool does: a pin or block port on no net is connected to the wire's net, and two such ends get a new net with no name (created_net in the reply). A junction with no net yet takes the wire's. Ends on two different nets are refused."
        case .placeJunction: "Create a schematic junction on a net, reusing a compatible or net-less junction at the same point. An id that names a junction already on a sheet moves it, and the wires, labels and power symbols on it go with it."
        case .setNetLineEndpoint: "Retarget one end of an existing wire, keeping its id and logical net."
        case .removeNetLine: "Remove a wire from its sheet, and any junction at its ends that it leaves holding nothing."
        case .removeJunction: "Remove a junction with the wires ending on it and the labels and power symbols sitting on it — net-less junctions included."
        case .pruneSheet: "Clear orphaned drawing from a sheet: wires with a dangling end, wiring islands that carry no net and reach no pin, labels on no net, and junctions nothing uses. unanchored and stubs widen it to wiring that names a net but reaches no pin, and wire ends to nowhere."
        case .terminatePin: "Draw a short wire straight out from a symbol pin and end it in a net label or power symbol facing away from the pin. Connects the pin to the net first when it is on none."
        case .setNoConnect: "Mark component pins as deliberately not connected, or clear the mark. A pin on a net is refused unless disconnect is passed. all does it for every free pin of a gate or the whole component, as Horizon's Set all unconnected pins NC and Clear all NC pins do."
        case .setPinAlternate: "Choose the function a pin is drawn as — an alternate name its unit offers, such as SPI1_SCK on an MCU port pin — or a custom name, or go back to the primary name. get_component lists each pin's alternates and what is selected. The apply_ops reply gives warnings when a placed symbol will not draw the choice (one showing pins custom_only)."
        case .remapPart: "Replace a component's part, preserving connections, symbols and wires atomically. Pins are matched by name, except where pin_map pairs them by name or gate/pin."
        case .placeText: "Write a text on a schematic sheet, or change one that is already there: move it, turn it, rewrite it. id names the text to change, from list_texts; give only what changes. x_mm, y_mm or both move it, and it keeps its uuid, layer and the rest. An id that names no text makes one under it, so a batch can name a text and edit or remove it later. A smashed symbol's texts (list_texts with smashed) are changed the same way, and go on drawing its refdes and value. The text starts at x_mm and runs right (origin is vertical alone); the reply gives the box it covers, extent_mm, and the symbols, labels, power symbols and texts it overlaps."
        case .removeText: "Remove a text from a schematic sheet."
        case .placePowerSymbol: "Draw a power symbol on a sheet: the ground or supply marker that says a point is on that net. Marks the net as a power net, since that is what one means."
        case .removePowerSymbol: "Remove a power symbol from its sheet."
        case .placeNetLabel: "Label a net on a sheet. A label is how a net is named on the page, and how one net spans several sheets. id naming a label that is there changes it in place — its orientation, size, off-sheet refs or place — as place_text changes a text."
        case .removeNetLabel: "Remove a net label from its sheet."
        case .addBlockInstance: "Use another block inside this one: one instance of it, with its own reference designator."
        case .removeBlockInstance: "Remove a block instance and every symbol drawn for it."
        case .connectBlockPort: "Connect a block instance's port to a net in the block that uses it. Ports are how a sub-block reaches the design around it."
        case .placeBlockSymbol: "Draw a block instance on a sheet, using the symbol that block defines for itself."
        case .removeBlockSymbol: "Take a block instance's symbol off its sheet. The instance stays."
        case .disconnectBlockPort: "Take a block instance's port off its net, or clear its no-connect mark."
        case .setBlockInstance: "Set a block instance's reference designator, which its symbol's $REFDES draws."
        case .addBlock: "Horizon's Add Block: a new block to use inside others — no parts yet, one empty sheet framed like the top block's first, and a template symbol (a box with $REFDES and $NAME). It shares the top block's net classes and power nets. Edit it with block set to its name or uuid."
        case .renameBlock: "Rename a block. Its symbols' $NAME draws the name."
        case .removeBlock: "Remove a block and its files. Refused for the top block and for a block any other block still uses."
        case .setNetPort: "Make a net of a sub-block one of its ports, which the blocks using it wire to their own nets, or stop it being one — which takes its port off the symbol, the instances' connections to it, and the wires that ended on it. Edit the sub-block with block. Power nets can't be ports."
        case .placeBlockPort: "Draw one of the edited block's ports on its symbol, as Horizon's Place Port does, or move or change it there. Its uuid is derived from its net."
        case .removeBlockPort: "Take a port off the edited block's symbol. The net stays a port; the instances' connections to it and the wires that ended on it go."
        case .annotate: "Horizon's Annotate: number every component's refdes from its prefix, sheet by sheet in the order given, across the whole design — each instance of a block numbered on its own, under its instance mapping. The options default to the schematic's own and are kept there."
        case .addRule: "Add a board design rule of a kind, with the defaults the app's own rules editor would give it and the fields given merged in, ordered after the rules of its kind already there. A via rule gets the padstack the board's via rules already use unless fields names one."
        case .setRule: "Change fields of a board design rule, merging objects key by key. The board is refused if the change makes the rules invalid. A change to the via rules gives the vias that take their shape from them the padstack and parameters of the rule that now matches."
        case .removeRule: "Remove a board design rule."
        case .setStackup: "Set how many inner copper layers the board has, and the copper and dielectric thicknesses."
        case .addSheet: "Add a schematic sheet, with the drawing frame the other sheets use. An index already taken inserts the sheet there and moves the later ones down."
        case .renameSheet: "Rename a schematic sheet."
        case .setSheetFrame: "Give a sheet the drawing frame its title block is drawn with, or none. The frame has to be in the project pool, where a sheet's frame is drawn from; list_sheets gives the frames the sheets use."
        case .removeSheet: "Remove a schematic sheet. A sheet with anything drawn on it is refused unless force is passed, which clears it — symbols included, though their components stay in the block."
        case .placeTrack: "Route one straight copper segment on a layer between two points, pads or junctions. Manual routing: it draws what it is told and does not find a path."
        case .removeTrack: "Remove a copper segment, and any junction it leaves holding nothing."
        case .setTrackWidth: "Set a copper segment's width."
        case .placeVia: "Put a via at a point, on a net, joining the layers its padstack spans. Its shape comes from the via rule that matches its net, unless a via definition or a size of its own is given; the reply says which and gives the size."
        case .removeVia: "Remove a via, and the junction it sat on when nothing else needs it."
        case .placePolygon: "Draw a closed polygon on a board layer. Layer 100 is the board outline, which is what gives a board its shape."
        case .removePolygon: "Remove a board polygon. A polygon a plane pours into belongs to that plane."
        case .placePlane: "Define a copper pour: a polygon on a copper layer, filled with one net. Defining it does not fill it — pour_planes does that."
        case .removePlane: "Remove a plane and the polygon it pours into."
        case .placeHole: "Put a hole through the board — a mounting hole, or a plated one on a net."
        case .removeHole: "Remove a board hole."
        case .placeKeepout: "Mark an area where copper may not go, on one layer or all of them."
        case .removeKeepout: "Remove a keepout and the polygon bounding it."
        case .placeBoardText: "Write a text on a board layer — silkscreen, assembly, fabrication notes — or change one that is there. As with place_text, an id from list_board_texts changes that text, and x_mm, y_mm or both move it; an id that names no text makes one under it."
        case .removeBoardText: "Remove a board text. A text a package carries belongs to that package."
        case .placeDimension: "Measure between two points on the board, the way the dimension tool does."
        case .removeDimension: "Remove a dimension."
        case .setSheetIndex: "Move a schematic sheet to a page number, shifting the sheets between; swap exchanges it with the one there instead."
        case .placeComponent: "Place a component's package on the board, or move it if it is placed."
        case .removePlacement: "Take a component's package off the board, keeping its copper as junctions."
        case .copyGroupLayout: "Copy the placement (and by default the routing) of one group's packages onto another group whose components carry the same tags."
        case .setProjectMeta: "Set the project's title-block values — project_title, project_name, rev, author and the rest — that $project_title and the like stand for on the sheets and the board. The schematic's own copies of a value change with it."
        case .setExportSettings: "Change the export settings Horizon EDA keeps in the project — Gerber, ODB, pick-and-place, STEP, board PDF, BOM, schematic PDF: file names, directories, options. export_settings shows them."
        }
    }

    /// The field an op names what it acts on with, for the ops whose field is
    /// not `id`. Each of them takes `id` for it too, so a caller doesn't have
    /// to know that remove_net_line says line and remove_track says track.
    static let targetFields: [Self: String] = [
        .removeNetLine: "line", .setNetLineEndpoint: "line", .removeJunction: "junction",
        .removeTrack: "track", .setTrackWidth: "track", .removeVia: "via",
        .removePolygon: "polygon", .removePlane: "plane", .removeHole: "hole", .removeKeepout: "keepout",
        .removeDimension: "dimension", .removeBus: "bus", .removeNetTie: "net_tie",
        .removeBlockInstance: "instance", .removeBlockSymbol: "instance", .setBlockInstance: "instance",
        .renameBlock: "block", .removeBlock: "block"
    ]

    var params: [String: String] {
        var params = ownParams
        if let field = Self.targetFields[self] {
            params["id"] = "The same as \(field), which it stands in for: every op takes id for what it acts on (optional)."
        }
        return params
    }

    private var ownParams: [String: String] {
        let component = "Reference designator, or component id (eight or more of its leading digits will do)."
        switch self {
        case .ensureComponent:
            return ["id": "Component UUID to use, or a name for it that later ops in the batch can use as its component (optional).", "refdes": "Reference designator (optional; defaults to the entity's prefix plus ?).", "part": "Pool part id.", "entity": "Pool entity id (when there is no part).", "value": "Value (optional).", "group": "Group name (optional).", "tag": "Tag name (optional)."]
        case .removeComponent:
            return ["component": component,
                    "texts_within_mm": "Also remove free text this close to the component's symbols when they are the nearest symbol to it — the notes that described the part (optional).",
                    "keep_wiring": "Leave the wiring that served only this part — the islands that reach no pin once it is gone, with their labels and power symbols, and the dead ends that ran to it (default false: they go with it)."]
        case .removePlacement:
            return ["component": component]
        case .setValue:
            return ["component": component, "value": "New value."]
        case .setRefdes:
            return ["component": component, "refdes": "New reference designator.",
                    "instance": "For a component of a sub-block, the instance whose refdes this is: instance refdes or uuids from the top block, joined with /, e.g. I1 or I1/I2 (optional; without it the block's own refdes, which every instance without one of its own shows)."]
        case .setPart:
            return ["component": component, "part": "Pool part id, or null."]
        case .setNoPopulate:
            return ["component": component, "no_populate": "true or false.",
                    "instance": "For a component of a sub-block, the instance it is (not) populated in, as set_refdes takes it (optional)."]
        case .setGroupTag:
            return ["component": component, "group": "Group name, or null.", "tag": "Tag name, or null."]
        case .ensureNet:
            return ["id": "Net UUID to use, or a name for it that later ops in the batch can use as its net (optional).", "name": "Net name; \"\" makes a new net with no name, which a batch reaches by its id (\"id\": \"n1\").", "net_class": "Net class name or id (optional).", "is_power": "Power net (optional)."]
        case .addBus:
            return ["name": "Bus name.", "id": "Bus UUID to use, or a name later ops in the batch can use for it (optional)."]
        case .removeBus:
            return ["bus": "Bus name or id."]
        case .addBusMember:
            return ["bus": "Bus name or id.", "name": "Member name within the bus.", "net": "Net name or id it carries.",
                    "id": "Member UUID to use, or a name later ops in the batch can use for it (optional)."]
        case .placeBusLabel:
            return ["bus": "Bus name or id. Optional when id names a bus label to change.",
                    "id": "A bus label id, from list_buses, to change in place: its orientation, size or place (optional; a new label otherwise, under this id when it is a UUID or a name for later ops).",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position. A new label needs both.", "y_mm": "Y position.",
                    "orientation": "right, left, up or down (optional; default right).",
                    "size_mm": "Cap height (optional; default 1.5)."]
        case .placeBusRipper:
            return ["bus": "Bus name or id.", "member": "Member name or id to take off.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "orientation": "up, down, left or right (optional; default up)."]
        case .addNetTie:
            return ["primary": "The net kept as the primary one.", "secondary": "The net tied to it.",
                    "id": "Net tie UUID to use, or a name later ops in the batch can use for it (optional)."]
        case .removeNetTie:
            return ["net_tie": "Net tie id."]
        case .placeNetTie:
            return ["net_tie": "Net tie id, from list_net_ties.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "from": "{\"x_mm\", \"y_mm\"} on the primary net.", "to": "{\"x_mm\", \"y_mm\"} on the secondary."]
        case .addNetClass:
            return ["name": "Net class name.", "id": "Net class UUID to use, or a name later ops in the batch can use for it (optional)."]
        case .renameNetClass:
            return ["net_class": "Net class name or id.", "name": "New name."]
        case .renameNet:
            return ["net": "Net name or id.", "name": "New name."]
        case .setNetClass:
            return ["net": "Net name or id.", "net_class": "Net class name or id."]
        case .retireNet:
            return ["net": "Net name or id.",
                    "remove_routing": "Also remove the board tracks and vias on the net, and its planes' outlines (default false: tracks and vias are counted in the result and left alone, on no net)."]
        case .connect:
            return ["component": component, "pin": "Pin name or uuid. A name is matched whole first, so one containing \"/\" works; otherwise gate/pin, by name or id.",
                    "gate": "Gate name, suffix or id, when the pin name is on several gates (optional).",
                    "net": "Net name or id; with create_net, \"\" or left out makes a new net with no name.",
                    "create_net": "Create the net when it does not exist (default false)."]
        case .disconnect:
            return ["component": component, "pin": "Pin as for connect.", "gate": "Gate, as for connect (optional)."]
        case .placeSymbol:
            return ["component": component, "gate": "Gate name, suffix or id; optional when the entity has one gate.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "symbol": "Pool symbol uuid to draw the gate with (optional; default the one symbol in the project pool for its unit).",
                    "x_mm": "X position.", "y_mm": "Y position.", "angle_deg": "Rotation (optional, default 0 or unchanged).",
                    "mirror": "Mirror the symbol (optional).",
                    "id": "Symbol instance UUID for a gate drawn for the first time, or a name such as \"u1a\" that later ops in the batch use for it in a wire end's symbol (optional).",
                    "pin_display_mode": "selected_only, custom_only, both or all (optional; default selected_only for a new symbol).",
                    "display_all_pads": "List every pad number on a pin that has several (optional; Horizon's default is true)."]
        case .moveToOtherSheet:
            return ["items": "What to move: ids of anything on the sheet (symbol instances, junctions, wires, net and bus labels, power symbols, bus rippers, net ties, block symbols, texts, graphic lines and arcs, pictures), or components by refdes or id, each standing for every gate of it drawn there. What they connect to comes too.",
                    "sheet": "The sheet they are on, by index, name or uuid (optional when they are all on one).",
                    "to_sheet": "The sheet to move them onto, by index, name or uuid.",
                    "dx_mm": "How far right to put them there (optional; default 0, where they were).", "dy_mm": "How far up (optional; default 0)."]
        case .moveSymbols:
            return ["symbols": "What to move: symbol instance ids from list_symbols, or components by refdes or id, each standing for every gate of it drawn on the sheet.",
                    "sheet": "The sheet they are on, by index, name or uuid (optional when they are all on one).",
                    "dx_mm": "How far right to move them (optional; default 0).", "dy_mm": "How far up (optional; default 0).",
                    "to_sheet": "Another sheet to move them onto, by index, name or uuid (optional; default the sheet they are on). The offset applies there too.",
                    "junctions": "More junction ids to carry, beyond the ones that belong only to these symbols (optional).",
                    "texts": "Free text ids to carry with them, such as notes about them (optional)."]
        case .setSymbolDisplay:
            return ["component": component, "gate": "Gate name, suffix or id; omitted, every drawn gate of the component.",
                    "symbol_instance": "One symbol instance id instead of component and gate (optional).",
                    "pin_display_mode": "selected_only, custom_only, both or all (optional).",
                    "display_all_pads": "List every pad number on a multi-pad pin (optional)."]
        case .smash, .unsmash:
            return ["component": component, "gate": "Gate name, suffix or id; omitted, every drawn gate of the component.",
                    "symbol_instance": "One symbol instance id instead of component and gate (optional).",
                    "board": "The component's package on the board instead of its symbols (default false)."]
        case .setCustomValue:
            return ["component": component, "gate": "Gate name, suffix or id; omitted, every drawn gate of the component.",
                    "symbol_instance": "One symbol instance id instead of component and gate (optional).",
                    "custom_value": "The text, e.g. \"${value}\\n${mpn}\"; \"\" or null clears it. Leading and trailing white space is trimmed, as Horizon trims it."]
        case .removeSymbol:
            return ["component": component, "gate": "Gate name, suffix or id; optional when the entity has one gate.",
                    "sheet": "Sheet index, name or uuid (optional; default every sheet).",
                    "texts_within_mm": "Also remove free text this close to the removed symbols when they are the nearest symbol to it (optional).",
                    "keep_wiring": "Leave the wiring that served only these symbols, ending on junctions where their pins were, as the app's delete leaves it (default false: it goes with them)."]
        case .drawNetLine:
            return ["component": component, "pin": "Pin as for connect.", "gate": "The pin's gate, as for connect (optional).",
                    "to_component": "The other end's component.",
                    "to_pin": "The other end's pin.", "to_gate": "The other pin's gate (optional).", "sheet": "Sheet index, name or uuid (optional).",
                    "id": "Wire UUID, or a name later ops in the batch can use as its line (optional; normalized ops carry the UUID).",
                    "from": "{kind: pin, symbol, pin} — pin a uuid or a name — or {kind: pin, component, gate?, pin} to find the symbol, {kind: port, instance, port} for a block instance's port where its block symbol draws it (instance an id or refdes, port its port net's name or uuid), or {kind: junction, junction}; use from/to OR the legacy component/pin fields. A junction with no net takes the other end's, and a port on no net is connected to it.",
                    "to": "The other typed endpoint, on the same sheet and net."]
        case .placeJunction:
            return ["id": "Junction UUID, or a name such as \"j1\" that later ops in the batch use as a wire end's junction (optional). The id of a junction already on a sheet moves that junction.",
                    "sheet": "Sheet index, name or uuid (optional).", "net": "Net name or id; optional when moving a junction, where it has to be the junction's own.",
                    "x_mm": "X position.", "y_mm": "Y position."]
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
                    "offsheet_refs": "Show the other sheets the net appears on beside the label, as for place_net_label (optional; default true).",
                    "style": "Power symbol style, as for place_power_symbol (optional)."]
        case .setNoConnect:
            return ["component": component, "pin": "One pin, as for connect.", "pins": "Several pins, as for connect.",
                    "gate": "Gate, as for connect (optional); with all, only that gate's pins.",
                    "all": "Every pin instead of pin or pins: marking takes the pins on no net and leaves connected ones alone; clearing takes every no-connect mark (default false).",
                    "no_connect": "true marks them not connected (default); false clears the mark.",
                    "disconnect": "Take a pin off its net to mark it (default false: a connected pin is refused)."]
        case .setPinAlternate:
            return ["component": component, "pin": "One pin, as for connect.", "gate": "Gate, as for connect (optional).",
                    "alternate": "The alternate for pin: a name or uuid, or a list to show several. A name is matched whole first, then by one of its \"/\" parts when only one alternate has it (SPI1_SCK finds SPI1_SCK/I2S1_CK); the primary name selects it. null or [] clears, which also removes an entry get_component marks redundant.",
                    "assignments": "Several pins at once: an object from pin, as for connect, to what alternate takes. Use instead of pin and alternate.",
                    "use_primary_name": "Also show the primary name beside the alternates (optional; default false).",
                    "custom_name": "A name of your own, shown with the alternates (optional; \"\" or null removes it).",
                    "custom_direction": "The direction that custom name has: input, output, bidirectional, open_collector, passive, power_input, power_output or not_connected (optional; default unchanged, else bidirectional)."]
        case .remapPart:
            return ["component": component, "part": "Target imported pool part id.",
                    "pin_map": "Optional object from pins of the old part to pins of the new one, each named as connect names a pin: by name or uuid, whole first (so VSSA/VREF- works), then as gate/pin, by name, suffix or uuid. Pins it leaves out are matched by gate and pin name; every connected or drawn pin has to map one way or the other.",
                    "symbols": "Optional object mapping target gate UUIDs to symbol UUIDs.",
                    "pad_map": "Optional old pad UUID to target pad UUID map for ambiguous physical pin mappings. A routed pad whose pin settles nothing goes to the pad of the same name.",
                    "copper": "What to do with tracks on pads the new part has nothing for, such as an exposed pad: refuse (default; the error names the pads) or drop, which removes them with the remap."]
        case .placeText:
            return ["text": "The text to write. Optional when changing an existing text's placement only.",
                    "id": "Text id to change (optional; a new text otherwise). list_texts returns them.",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position. A new text needs both; for one that is there, either alone moves it along that axis.",
                    "y_mm": "Y position. A new text needs both; for one that is there, either alone moves it along that axis.",
                    "angle_deg": "Rotation (optional, default 0 or unchanged).", "mirror": "Mirror the text (optional).",
                    "size_mm": "Cap height (optional; default 1.5).", "width_mm": "Stroke width (optional; default 0, which is Horizon's automatic width).",
                    "origin": "baseline, center or bottom (optional; default center). It places the text vertically only: x_mm is always where the text starts, its left end before any turn.",
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
            return ["net": "Net name or id. Optional when id names a label to change, which keeps its net.",
                    "id": "A net label id, from list_net_labels, to change in place: its orientation, size, off-sheet refs or place, keeping its id (optional; a new label otherwise, under this id when it is a UUID or a name for later ops).",
                    "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position. A new label needs both; a label that is there moves along the axes given, onto a junction or wire there.",
                    "y_mm": "Y position.",
                    "orientation": "right, left, up or down (optional; default right, or unchanged).",
                    "size_mm": "Cap height (optional; default 1.5, or unchanged).",
                    "offsheet_refs": "Show the other sheets this net appears on (optional; default true, or unchanged).",
                    "show_port": "On a sub-block's port net, Horizon's Show port: the label reads the port's direction, IN: name (optional)."]
        case .removeNetLabel:
            return ["id": "Net label id, from list_net_labels."]
        case .addBlockInstance:
            return ["block": "The block to use, by uuid or name.", "refdes": "Reference designator for this use of it (optional).",
                    "id": "Instance UUID to use, or a name later ops in the batch can use as its instance (optional)."]
        case .removeBlockInstance:
            return ["instance": "Block instance id or refdes."]
        case .connectBlockPort:
            return ["instance": "Block instance id or refdes.", "port": "Port uuid on the used block, or the net name it carries there.",
                    "net": "Net name or id in this block.", "create_net": "Create the net when it does not exist (default false).",
                    "nc": "Mark the port not connected instead, as Horizon's Set NC does (optional; net is then not needed)."]
        case .disconnectBlockPort:
            return ["instance": "Block instance id or refdes.", "port": "Port uuid on the used block, or the net name it carries there."]
        case .setBlockInstance:
            return ["instance": "Block instance id or refdes.", "refdes": "New reference designator."]
        case .addBlock:
            return ["name": "The block's name.", "id": "Block uuid to use (optional)."]
        case .renameBlock:
            return ["block": "The block, by uuid or name.", "name": "New name."]
        case .removeBlock:
            return ["block": "The block, by uuid or name."]
        case .setNetPort:
            return ["net": "Net name or id in the edited block.", "is_port": "Whether it is a port (default true).",
                    "port_direction": "input, output, bidirectional, open_collector, power_input, power_output, passive or not_connected (optional)."]
        case .placeBlockPort:
            return ["net": "The port's net in the edited block.", "x_mm": "X position of the port's outer end, where wires join it.",
                    "y_mm": "Y position.", "orientation": "left, right, up or down: the way it points out of the symbol (optional; default the last port's, else right).",
                    "length_mm": "Length (optional; default 2.5).", "name_orientation": "in_line, perpendicular or horizontal (optional; default in_line)."]
        case .removeBlockPort:
            return ["net": "The port's net in the edited block."]
        case .annotate:
            return ["mode": "sequential, sheet_100 or sheet_1000: numbers running on, or starting at 100 or 1000 times the sheet's page (optional).",
                    "order": "right_down or down_right: the order a sheet's symbols are taken in (optional).",
                    "fill_gaps": "Reuse numbers left free (optional).",
                    "keep": "Keep refdes already given, numbering only those with ? (optional).",
                    "ignore_unknown": "Keep a refdes whose number can't be read, rather than numbering it again (optional)."]
        case .placeBlockSymbol:
            return ["instance": "Block instance id or refdes.", "sheet": "Sheet index, name or uuid (optional; default the first sheet).",
                    "x_mm": "X position.", "y_mm": "Y position.",
                    "angle_deg": "Rotation (optional).", "mirror": "Mirror the symbol (optional)."]
        case .removeBlockSymbol:
            return ["instance": "Block instance id or refdes.", "sheet": "Sheet index, name or uuid (optional; default every sheet)."]
        case .addRule:
            return ["kind": "Rule kind, e.g. clearance_copper or track_width. board_rules lists the kinds.",
                    "id": "Rule id to use, for a kind that holds several (optional).",
                    "fields": "Object of fields to merge into the defaults, as set_rule merges them, so a rule is made whole in one op (optional)."]
        case .setRule:
            return ["kind": "Rule kind.", "id": "Rule id, for a kind that holds several. board_rules returns them.",
                    "fields": "Object of fields to merge into the rule. An object merges into the object there key by key — a match's net, a parameter set's via_diameter — and anything else replaces what was there. board_rules shows what a rule of that kind holds."]
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
        case .setSheetFrame:
            return ["sheet": "Sheet index, name or uuid.",
                    "frame": "Pool frame uuid, which the project pool must have, or \"none\" (or null) for no frame."]
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
                    "x_mm": "X position. A new text needs both; for one that is there, either alone moves it along that axis.",
                    "y_mm": "Y position. A new text needs both; for one that is there, either alone moves it along that axis.",
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
                    "definition": "A board via definition to take the padstack and size from, by name (\"mini\") or uuid (optional).",
                    "diameter_mm": "The via's own diameter, which makes its shape its own rather than the rules' (optional).",
                    "hole_mm": "The via's own drill diameter, likewise (optional).",
                    "padstack": "Pool padstack uuid for a via shaped by itself (optional). Without any of these the via takes the padstack and size of the first via rule that matches its net, as Horizon gives it them."]
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
        case .setProjectMeta:
            return ["values": "Object of title-block keys to set, e.g. {\"project_title\": \"Billo\", \"rev\": \"2A\"}. A key is what $key stands for in a frame or text; project_name, project_title, rev, author, date and license are the usual ones. null or \"\" removes a key."]
        case .setExportSettings:
            return ["kind": "Which settings: gerber, odb, pick_and_place, board_step, board_pdf, bom or schematic_pdf.",
                    "fields": "Object of fields to change, merged into the settings, e.g. {\"output_directory\": \"Billo Fabrication\"}. Only fields the settings already hold, each with a value of the same type; export_settings shows them."]
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
        var json = json
        if let field = HorizontalEditOperationKind.targetFields[kind], let id = json["id"] {
            if let given = json[field], (given as? String)?.caseInsensitiveCompare(id as? String ?? "") != .orderedSame {
                throw HorizontalDispatchError.invalidParams("\(name) names what it acts on by \(field) or by id; give one of them.")
            }
            json[field] = id
            json.removeValue(forKey: "id")
        }
        let unknown = Set(json.keys).subtracting(Set(kind.params.keys).union(["op"]))
        guard unknown.isEmpty else { throw HorizontalDispatchError.invalidParams("Unknown \(name) fields: \(unknown.sorted().joined(separator: ", ")).") }
        for (key, value) in json where key != "op" {
            if key == "mode", kind != .annotate {
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
            } else if key == "items", kind == .moveToOtherSheet {
                guard let list = value as? [Any], !list.isEmpty, list.allSatisfy({ $0 is String }) else {
                    throw HorizontalDispatchError.invalidParams("items must be a non-empty array of ids.")
                }
            } else if ["symbols", "junctions", "texts"].contains(key), kind == .moveSymbols {
                guard let list = value as? [Any], list.allSatisfy({ $0 is String }), key != "symbols" || !list.isEmpty else {
                    throw HorizontalDispatchError.invalidParams("\(key) must be an array of ids\(key == "symbols" ? ", not empty" : "").")
                }
            } else if key == "to_sheet" {
                guard value is String || value is NSNumber else {
                    throw HorizontalDispatchError.invalidParams("to_sheet must be a sheet index, name or uuid.")
                }
            } else if ["layer", "index", "priority", "inner_layers"].contains(key) {
                try HorizontalDispatchValidation.number(value, key: key, integer: true)
            } else if key == "alternate" {
                // A name, several, or null to go back to the primary name.
                guard value is String || value is NSNull || (value as? [Any])?.allSatisfy({ $0 is String }) == true else {
                    throw HorizontalDispatchError.invalidParams("alternate must be a name or uuid, a list of them, or null.")
                }
            } else if key == "assignments" {
                guard let table = value as? JSONDictionary, !table.isEmpty, table.values.allSatisfy({
                    $0 is String || $0 is NSNull || ($0 as? [Any])?.allSatisfy({ $0 is String }) == true
                }) else {
                    throw HorizontalDispatchError.invalidParams("assignments must be an object from pin to an alternate name, a list of them, or null.")
                }
            } else if value is NSNull, ["custom_name", "custom_value", "frame"].contains(key) {
                continue
            } else if ["fields", "pin_map", "symbols", "pad_map", "values"].contains(key), kind != .moveSymbols {
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
                       "label_distance_mm", "length_mm", "texts_within_mm", "diameter_mm", "hole_mm", "dx_mm", "dy_mm"].contains(key) {
                try HorizontalDispatchValidation.number(value, key: key)
            } else if ["no_populate", "is_power", "create_net", "bottom", "include_routing", "mirror", "offsheet_refs", "exposed_copper_only",
                       "force", "cascade", "swap", "remove_routing", "display_all_pads", "no_connect", "disconnect",
                       "unanchored", "stubs", "use_primary_name", "all", "keep_wiring", "board", "is_port", "nc", "show_port", "fill_gaps", "keep", "ignore_unknown"].contains(key) {
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
    func remove(_ url: URL) throws
}

struct HorizontalDiskFileStore: HorizontalProjectFileStore {
    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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

    func remove(_ url: URL) throws {
        guard let path = relativePath(for: url) else {
            throw HorizontalDispatchError.failed("Could not map \(url.path) into the document archive rooted at \(baseURL.path).")
        }
        try archive.removeRegularFile(relativePath: path)
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
    /// The project as the transaction holds it, when the editor runs in one:
    /// what `pool_write` or `pool_items` wrote is here before it is on disk.
    private let snapshot: HorizontalDispatchSnapshot?
    private var files: [String: JSONDictionary] = [:]
    private var fileURLs: [String: URL] = [:]
    private var dirty = Set<String>()
    /// Files an op took out of the project, by path from its base.
    private var removedFiles: [String] = []
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
        self.snapshot = snapshot
        pool = HorizontalDispatchPoolIndex(project: project, snapshot: snapshot)
        poolURL = project.poolDirectory.map { project.baseURL.appendingPathComponent($0) }

        let top = project.blocks.first(where: \.isTop)
        var selected = top
        if let reference, !reference.isEmpty {
            let matches = HorizontalProjectBlock.matching(reference, in: project.blocks)
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
        for (index, operation) in operations.enumerated() {
            var operation = operation
            if !reusedIDs.isEmpty { operation.params = withReusedIDs(operation.params) }
            do {
                try apply(operation)
            } catch let error as HorizontalDispatchError {
                // Which op of forty failed is the first thing a caller needs.
                throw error.inOperation(index, operation.kind.rawValue)
            }
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
            let before = try debris(onSheetsDrawing: id, gate: nil, keep: params.bool("keep_wiring") ?? false)
            change["removed"] = removeComponent(id)
            if !notes.isEmpty { change["texts_removed"] = try removeFreeTexts(notes) }
            if let wiring = try clearDebris(since: before) { change["wiring_removed"] = wiring }
        case .setValue:
            let id = try componentID(params)
            guard let value = params["value"] as? String else {
                throw HorizontalDispatchError.invalidParams("set_value needs \"value\".")
            }
            try updateComponent(id) { $0["value"] = value }
            change["component"] = id
            change["value"] = value
            // Horizon shows a part's own value over the component's. Whether
            // that hides this one is said in warnings(), once the batch has
            // run, since a set_part later in it can change the part.
        case .setRefdes:
            let id = try componentID(params)
            guard let refdes = params.string("refdes"), !refdes.isEmpty else {
                throw HorizontalDispatchError.invalidParams("set_refdes needs \"refdes\".")
            }
            if params.string("instance") != nil {
                change["instance"] = try updateInstanceMapping(component: id, params) { $0["refdes"] = refdes }
            } else {
                try updateComponent(id) { $0["refdes"] = refdes }
            }
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
            if params.string("instance") != nil {
                change["instance"] = try updateInstanceMapping(component: id, params) { $0["nopopulate"] = flag }
            } else {
                try updateComponent(id) { $0["nopopulate"] = flag }
            }
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
            let unnamed = (params.string("net") ?? "").isEmpty
            if unnamed, params.bool("create_net") ?? false {
                // A net of its own with no name, as a wire from a free pin
                // makes one in Horizon's wire tool.
                net = try ensureNet(["name": ""]).0
            } else if let existing = try existingNetID(params) {
                net = existing
            } else if params.bool("create_net") ?? false, let name = params.string("net") {
                net = try ensureNet(["name": name]).0
            } else {
                throw HorizontalDispatchError.notFound("No net matches \(params["net"] ?? "nothing"); pass create_net to make it.")
            }
            try connect(id, pin: pin, to: net)
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
            touchedPins.insert("\(id)|\(pin.lowercased())")
            change["component"] = id
            change["pin"] = pin
        case .placeSymbol:
            let id = try componentID(params)
            change["component"] = id
            change.merge(try placeSymbol(id, params)) { _, new in new }
        case .moveSymbols:
            change.merge(try moveSymbols(params)) { _, new in new }
        case .moveToOtherSheet:
            change.merge(try moveToOtherSheet(params)) { _, new in new }
        case .removeSymbol:
            let id = try componentID(params)
            change["component"] = id
            let gateID = params.string("gate") == nil ? nil : try gate(params, componentID: id).id
            let notes = try textsNear(componentID: id, gateID: gateID, sheet: params["sheet"] == nil ? nil : try sheetID(params), params)
            let before = try debris(onSheetsDrawing: id, gate: gateID, keep: params.bool("keep_wiring") ?? false)
            change["removed"] = try removeSymbol(id, params)
            if !notes.isEmpty { change["texts_removed"] = try removeFreeTexts(notes) }
            if let wiring = try clearDebris(since: before) { change["wiring_removed"] = wiring }
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
        case .setCustomValue:
            change.merge(try setCustomValue(params)) { _, new in new }
        case .smash, .unsmash:
            change.merge(try smash(params, smashing: operation.kind == .smash)) { _, new in new }
        case .setNoConnect:
            change.merge(try setNoConnect(params)) { _, new in new }
        case .setPinAlternate:
            change.merge(try setPinAlternate(params)) { _, new in new }
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
        case .disconnectBlockPort:
            change.merge(try disconnectBlockPort(params)) { _, new in new }
        case .setBlockInstance:
            change.merge(try setBlockInstance(params)) { _, new in new }
        case .addBlock:
            change.merge(try addBlock(params)) { _, new in new }
        case .renameBlock:
            change.merge(try renameBlock(params)) { _, new in new }
        case .removeBlock:
            change.merge(try removeBlock(params)) { _, new in new }
        case .setNetPort:
            change.merge(try setNetPort(params)) { _, new in new }
        case .placeBlockPort:
            change.merge(try placeBlockPort(params)) { _, new in new }
        case .removeBlockPort:
            change.merge(try removeBlockPort(params)) { _, new in new }
        case .annotate:
            change.merge(try annotate(params)) { _, new in new }
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
        case .setSheetFrame:
            change.merge(try setSheetFrame(params)) { _, new in new }
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
            let id = try boardComponentID(params)
            change["component"] = id
            change["package"] = try placeComponent(id, params)
        case .removePlacement:
            let id = try boardComponentID(params)
            change["component"] = id
            change["removed_packages"] = removeBoardPackages(componentID: id)
        case .copyGroupLayout:
            let result = try copyGroupLayout(params)
            change.merge(result) { _, new in new }
        case .setProjectMeta:
            change.merge(try setProjectMeta(params)) { _, new in new }
        case .setExportSettings:
            change.merge(try setExportSettings(params)) { _, new in new }
        }
        changes.append(change)
    }

    /// Ids a batch gave things that turned out to be there already, each with
    /// the one it is: a junction placed where one stands is that junction, so
    /// a later op naming the id it was given means the one reused.
    private(set) var reusedIDs: [String: String] = [:]

    /// `json` with every id the batch gave a reused thing replaced by that
    /// thing's own: what later ops see, and what the normalized ops replay.
    func withReusedIDs(_ json: JSONDictionary) -> JSONDictionary {
        func replaced(_ value: Any) -> Any {
            switch value {
            case let text as String: return reusedIDs[text.lowercased()] ?? text
            case let map as JSONDictionary: return map.mapValues(replaced)
            case let list as [Any]: return list.map(replaced)
            default: return value
            }
        }
        return json.mapValues(replaced)
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
        for path in removedFiles {
            let url = project.baseURL.appendingPathComponent(path)
            try store.remove(url)
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
        // An id copied from a reply as "33b623e6…" names the one id it begins.
        if let match = try HorizontalDispatchValidation.id(matchingPrefix: reference, in: all.keys, kind: "component") {
            return match
        }
        throw HorizontalDispatchError.notFound("No component \(reference).")
    }

    /// The component a board op names: the block's own, or a use of a
    /// sub-block's component in one instance, by the flat uuid or refdes the
    /// flattened block gives it — what the board places a package for.
    private func boardComponentID(_ params: JSONDictionary) throws -> String {
        do {
            return try componentID(params)
        } catch let error as HorizontalDispatchError where error.code == .notFound {
            guard isTopBlock, let flattened = project.flattenedBlock, let reference = params.string("component") else { throw error }
            let instances = flattened.json.dictionaryMap("components").filter { flattened.componentPaths[$0.key.lowercased()]?.count ?? 0 > 1 }
            if let match = instances.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }) {
                return match.lowercased()
            }
            let named = instances.filter { $0.value.string("refdes") == reference }
            guard named.count <= 1 else {
                throw HorizontalDispatchError.invalidParams("\(named.count) components are named \(reference); use the id.")
            }
            if let match = named.first { return match.key.lowercased() }
            if let match = try HorizontalDispatchValidation.id(matchingPrefix: reference, in: instances.keys, kind: "component") {
                return match.lowercased()
            }
            throw error
        }
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
        // A part may set its own refdes prefix in place of its entity's, as
        // Horizon's Component::get_prefix has it.
        var prefix: String?
        if let partID {
            guard let part = poolPart(partID) else {
                throw HorizontalDispatchError.notFound("No pool part \(partID).")
            }
            entityID = part.entityID?.lowercased() ?? entityID
            prefix = part.prefixOverride
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
            "refdes": params.string("refdes") ?? "\(prefix ?? (entity.prefix.isEmpty ? "X" : entity.prefix))?",
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

    /// The project's part list leaves out a part another derives from, so
    /// such a part is read from the pool index (the snapshot), then off disk.
    private func poolPart(_ id: String) -> HorizontalPoolPart? {
        if let part = project.poolParts.first(where: { $0.id.lowercased() == id }) {
            return part
        }
        if let part = pool.poolPart(id) {
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
        // An unnamed net has only its id, which a reply shortens to its first
        // eight digits; that names it when no other net's id begins the same.
        if let match = try HorizontalDispatchValidation.id(matchingPrefix: reference, in: all.keys, kind: "net") {
            return match
        }
        throw HorizontalDispatchError.notFound("No net \(reference).")
    }

    /// A component's pin, `gate uuid/pin uuid`, onto a net.
    private func connect(_ componentID: String, pin: String, to net: String) throws {
        try updateComponent(componentID) { component in
            var connections = component["connections"] as? JSONDictionary ?? [:]
            connections[pin] = ["net": net]
            component["connections"] = connections
        }
        touchedPins.insert("\(componentID)|\(pin.lowercased())")
    }

    /// The net `params` names, or nil when it names none, so a caller can
    /// make it; a name or short id that fits several nets is still an error.
    private func existingNetID(_ params: JSONDictionary) throws -> String? {
        do {
            return try netID(params)
        } catch let error as HorizontalDispatchError where error.code == .notFound {
            return nil
        }
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
        // "" is a net with no name, which no name can find, so it is always new.
        guard let name = params.string("name") else {
            throw HorizontalDispatchError.invalidParams("ensure_net needs a \"name\" (\"\" for a net with none).")
        }
        if params.string("id") == nil, !name.isEmpty, let existing = try? netID(reference: name) {
            return (existing, false)
        }
        guard !name.isEmpty || params.bool("is_power") != true else {
            throw HorizontalDispatchError.invalidParams("A power net needs a name.")
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
                // A track or via can be on no net; a plane can't. Horizon drops
                // one whose net is gone when it opens the board, so leaving it
                // would leave a plane only this file believes in. Its outline
                // stays, as a polygon.
                if !planes.isEmpty {
                    try updateBoard { json in
                        var planeMap = json.dictionaryMap("planes")
                        for planeID in planes.keys { planeMap.removeValue(forKey: planeID) }
                        json["planes"] = planeMap
                    }
                    board["planes_removed"] = planes.count
                }
                board["removed"] = false
                let planesNote = "Its planes are removed, since a plane needs a net, and their outlines stay as polygons."
                if planes.isEmpty {
                    board["note"] = "Copper on this net is left in place, on no net; pass remove_routing to remove it."
                } else if tracks.isEmpty && vias.isEmpty {
                    board["note"] = planesNote
                } else {
                    board["note"] = "Tracks and vias on this net are left in place, on no net; pass remove_routing to remove them. " + planesNote
                }
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
            if let existing = try existingNetID(params) {
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
            if let refs = params.bool("offsheet_refs") { mark["offsheet_refs"] = refs }
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
        let mark = params.bool("no_connect") ?? true
        if params.bool("all") == true {
            guard references.isEmpty else { throw HorizontalDispatchError.invalidParams("set_no_connect takes all or pin/pins, not both.") }
            return try setAllNoConnect(componentID: componentID, gate: params.string("gate"), mark: mark, params: params)
        }
        guard !references.isEmpty else { throw HorizontalDispatchError.invalidParams("set_no_connect needs \"pin\", \"pins\" or \"all\".") }
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
        var change: JSONDictionary = ["component": componentID, "pins": paths, "no_connect": mark,
                                      "pin_names": paths.map { pinName($0, componentID: componentID) }]
        if !taken.isEmpty { change["disconnected"] = taken }
        return change
    }

    /// Horizon's Set all unconnected pins NC and Clear all NC pins
    /// (`ToolSetNotConnectedAll`): marking adds a null-net connection for each
    /// pin with no connection at all; clearing removes each null-net one.
    private func setAllNoConnect(componentID: String, gate: String?, mark: Bool, params: JSONDictionary) throws -> JSONDictionary {
        guard let entityID = components()[componentID]?.string("entity"), let entity = pool.entity(entityID) else {
            throw HorizontalDispatchError.notFound("Component \(componentID) has no entity in the project pool.")
        }
        let only = gate == nil ? nil : try self.gate(params, componentID: componentID).id
        var connections = components()[componentID]?.dictionary("connections") ?? [:]
        var keys = [String: String]()
        for key in connections.keys { keys[key.lowercased()] = key }
        var paths = [String]()
        for (gateID, gate) in entity.gates.sorted(by: { $0.key < $1.key }) where only == nil || gateID == only {
            guard let unitID = gate.unitID, let unit = pool.unit(unitID) else { continue }
            for pinID in unit.pins.keys.sorted() {
                let path = "\(gateID)/\(pinID)"
                let key = keys[path]
                if mark, key == nil {
                    connections[path] = ["net": NSNull()]
                    paths.append(path)
                } else if !mark, let key, (connections[key] as? JSONDictionary)?.string("net") == nil {
                    connections.removeValue(forKey: key)
                    paths.append(path)
                }
            }
        }
        if !paths.isEmpty { try updateComponent(componentID) { $0["connections"] = connections } }
        // By name as a person reads them (PC1, PC3_C, PC8, …), not by uuid.
        paths.sort {
            let order = pinName($0, componentID: componentID).localizedStandardCompare(pinName($1, componentID: componentID))
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return ["component": componentID, "pins": paths, "no_connect": mark, "all": true,
                "pin_names": paths.map { pinName($0, componentID: componentID) }]
    }

    // MARK: - Pin alternates

    /// Horizon keeps a component's choice of pin function in `alt_pins`, keyed
    /// by gate/pin path: the chosen alternates by uuid, whether the primary name
    /// still shows, and a custom name. A pin with nothing chosen has no entry.
    private func setPinAlternate(_ params: JSONDictionary) throws -> JSONDictionary {
        let componentID = try componentID(params)
        let refdes = components()[componentID]?.string("refdes") ?? componentID
        var requests = [(pin: String, alternate: Any?)]()
        if let assignments = params["assignments"] {
            guard params["pin"] == nil, params["alternate"] == nil else {
                throw HorizontalDispatchError.invalidParams("set_pin_alternate takes assignments or pin and alternate, not both.")
            }
            guard let table = assignments as? JSONDictionary, !table.isEmpty else {
                throw HorizontalDispatchError.invalidParams("assignments must be an object from pin to alternate.")
            }
            requests = table.keys.sorted().map { ($0, table[$0]) }
        } else if let pin = params.string("pin") {
            requests = [(pin, params["alternate"])]
        } else {
            throw HorizontalDispatchError.invalidParams("set_pin_alternate needs \"pin\" or \"assignments\".")
        }
        let usePrimary = params.bool("use_primary_name")
        let customName: String? = params["custom_name"] is NSNull ? "" : params.string("custom_name")
        let customDirection = params.string("custom_direction")
        if let customDirection, HorizontalPinDirection(rawValue: customDirection) == nil {
            throw HorizontalDispatchError.invalidParams("custom_direction \(customDirection) is not a pin direction: "
                + HorizontalPinDirection.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }

        var altPins = components()[componentID]?.dictionary("alt_pins") ?? [:]
        var results = [JSONDictionary]()
        var seen = Set<String>()
        for request in requests {
            var selector: JSONDictionary = ["pin": request.pin]
            if let gate = params.string("gate") { selector["gate"] = gate }
            let path = try pinPath(selector, componentID: componentID)
            guard seen.insert(path).inserted else {
                throw HorizontalDispatchError.invalidParams("\(refdes) pin \(pinName(path, componentID: componentID)) is assigned twice.")
            }
            let unitPin = try self.unitPin(path, componentID: componentID)
            let wanted: [String]
            switch request.alternate {
            case nil, is NSNull: wanted = []
            case let name as String: wanted = [name]
            case let names as [Any]:
                wanted = try names.map {
                    guard let name = $0 as? String else { throw HorizontalDispatchError.invalidParams("An alternate is a name or uuid string.") }
                    return name
                }
            default:
                throw HorizontalDispatchError.invalidParams("An alternate is a name, a list of names, or null.")
            }
            var chosen = [HorizontalUnitPinAlternateName]()
            var primary = usePrimary ?? false
            for name in wanted {
                if name.caseInsensitiveCompare(unitPin.name) == .orderedSame {
                    primary = true
                    continue
                }
                let alternate = try alternate(name, of: unitPin, pin: "\(refdes) pin \(unitPin.name)")
                if !chosen.contains(where: { $0.id == alternate.id }) { chosen.append(alternate) }
            }

            let key = altPins.keys.first { $0.lowercased() == path } ?? path
            let before = altPins[key] as? NSDictionary
            let existing = altPins[key] as? JSONDictionary ?? [:]
            let custom = customName ?? (existing.bool("use_custom_name") == true ? existing.string("custom_name") ?? "" : "")
            altPins.removeValue(forKey: key)
            // An alternate on its own replaces the primary name, as picking it
            // in the app does. With nothing chosen the pin is back to its
            // primary name, which is what no entry means.
            if !chosen.isEmpty || !custom.isEmpty {
                altPins[path] = [
                    "custom_direction": customDirection ?? existing.string("custom_direction") ?? "bidirectional",
                    "custom_name": custom,
                    "pin_names": chosen.map { $0.id.lowercased() },
                    "use_custom_name": !custom.isEmpty,
                    "use_primary_name": primary
                ] as JSONDictionary
            }
            var result: JSONDictionary = ["pin": path, "pin_name": unitPin.name, "alternates": chosen.map(\.name)]
            if !custom.isEmpty { result["custom_name"] = custom }
            if altPins[path] == nil { result["cleared"] = true } else { result["primary"] = primary }
            // Asking for what the pin already has writes nothing.
            if key == path, before == altPins[path] as? NSDictionary { result["unchanged"] = true }
            results.append(result)
        }
        try updateComponent(componentID) { $0["alt_pins"] = altPins }
        var change: JSONDictionary = ["component": componentID, "pins": results]
        let unchanged = results.filter { $0.bool("unchanged") == true }.compactMap { $0.string("pin_name") }
        if !unchanged.isEmpty { change["unchanged_pins"] = unchanged }
        return change
    }

    /// What the batch asked for that the project will not show: alternates a
    /// custom_only symbol hides, and values a part's own value hides.
    /// Checked once the whole batch has run, so a later op in it counts.
    /// Pins whose net an op changed, as "component|gate/pin", for the copper
    /// warnings once the batch is done.
    private var touchedPins = Set<String>()

    /// A pin moved to another net, or off its net, with copper ending on its
    /// pad: the tracks still join it to what they joined it to before, so now
    /// they short two nets. The netlist never sees that, and only `check`'s
    /// copper pass would say so afterwards.
    private func copperWarnings() -> [String] {
        guard isTopBlock, !touchedPins.isEmpty, let board = files["board"] else { return [] }
        let packages = board.dictionaryMap("packages")
        let tracks = board.dictionaryMap("tracks")
        let loaded = Dictionary((project.board?.tracks ?? []).map { ($0.id.lowercased(), $0.netID?.lowercased()) }, uniquingKeysWith: { first, _ in first })
        func name(_ net: String?) -> String {
            guard let net else { return "no net" }
            let name = nets()[net]?.string("name") ?? ""
            return name.isEmpty ? net : name
        }
        var warnings = [String]()
        for key in touchedPins.sorted() {
            let pieces = key.split(separator: "|").map(String.init)
            guard pieces.count == 2, let component = components()[pieces[0]], let partID = component.string("part"),
                  let package = packages.first(where: { $0.value.string("component")?.lowercased() == pieces[0] })?.key.lowercased() else { continue }
            let net = component.dictionary("connections")?.first { $0.key.lowercased() == pieces[1] }
                .flatMap { ($0.value as? JSONDictionary)?.string("net")?.lowercased() }
            let refdes = component.string("refdes") ?? pieces[0]
            for pad in pool.terminals(partID: partID) where pad.string("gate_pin_path")?.lowercased() == pieces[1] {
                guard let padID = pad.string("id")?.lowercased() else { continue }
                let onPad = tracks.filter { _, track in
                    ["from", "to"].contains { track.dictionary($0)?.string("pad")?.lowercased() == "\(package)/\(padID)" }
                }
                let carried = Set(onPad.compactMap { id, track in loaded[id.lowercased()] ?? track.string("net")?.lowercased() })
                guard !onPad.isEmpty, carried.contains(where: { $0 != net }) else { continue }
                let padName = pad.string("name") ?? padID
                warnings.append(
                    "\(refdes) pad \(padName) is now on \(name(net)), and \(onPad.count) track\(onPad.count == 1 ? "" : "s") on it carr\(onPad.count == 1 ? "ies" : "y") "
                        + "\(carried.map(name).sorted().joined(separator: ", ")): \(onPad.keys.sorted().prefix(4).joined(separator: ", ")). "
                        + "list_tracks with component \(refdes), pads [\"\(padName)\"] and connected finds that copper; until it goes, check reports the short.")
            }
        }
        return warnings
    }

    func warnings() -> [String] {
        hiddenAlternateWarnings() + hiddenValueWarnings() + copperWarnings()
    }

    /// Horizon shows a part's own value wherever a value is shown, so one
    /// set_value writes on a part-backed component changes the file and
    /// nothing anyone sees. A value equal to the part's hides nothing.
    /// The way out is another part, and a part in another package changes
    /// the footprint too, so the warning gives the search that keeps the
    /// package. It says nothing of whether one exists: finding out would
    /// scan every pool from inside a dry run, and that search is one call.
    private func hiddenValueWarnings() -> [String] {
        var set = [String: String]()   // component → the last value the batch set
        for change in changes where change.string("op") == HorizontalEditOperationKind.setValue.rawValue {
            guard let id = change.string("component")?.lowercased(), let value = change.string("value") else { continue }
            set[id] = value
        }
        return set.compactMap { id, value -> (String, String)? in
            guard let component = components()[id], let partID = component.string("part")?.lowercased(),
                  let part = poolPart(partID), !part.displayValue.isEmpty, part.displayValue != value else { return nil }
            let refdes = component.string("refdes") ?? id
            let search = part.searchPackage.map {
                "search_pool with query \"\(value)\" and package \"\($0)\" lists those in \(refdes)'s package, "
                    + "and a part in another one changes \(refdes)'s footprint too."
            } ?? "search_pool with query \"\(value)\" lists them."
            return (refdes, "\(refdes) is part \(part.mpn.isEmpty ? partID : part.mpn), whose own value \(part.displayValue) is the one shown, "
                + "so the \(value) set_value wrote does not show. set_part to a part with the value \(value) "
                + "changes what is shown; \(search)")
        }
        .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        .map(\.1)
    }

    /// A symbol whose pin_display_mode is custom_only draws only custom
    /// names, so an alternate set_pin_alternate chose stays invisible on it,
    /// and so does every alternate its gate already had when
    /// set_symbol_display turns it custom_only. A set_symbol_display anywhere
    /// in the batch counts either way.
    private func hiddenAlternateWarnings() -> [String] {
        var wanted = [String: [String: String]]()   // component → gate/pin path → pin name
        var turned = Set<String>()                  // symbol instances this batch made custom_only
        for change in changes {
            switch change.string("op") {
            case HorizontalEditOperationKind.setPinAlternate.rawValue:
                guard let componentID = change.string("component")?.lowercased() else { continue }
                for pin in change["pins"] as? [JSONDictionary] ?? [] {
                    guard let path = pin.string("pin")?.lowercased(), !(pin["alternates"] as? [String] ?? []).isEmpty,
                          pin.string("custom_name") == nil else { continue }
                    wanted[componentID, default: [:]][path] = pin.string("pin_name") ?? path
                }
            case HorizontalEditOperationKind.setSymbolDisplay.rawValue where change.string("pin_display_mode") == "custom_only":
                for id in change["symbol_instances"] as? [String] ?? [] { turned.insert(id.lowercased()) }
            default:
                continue
            }
        }
        guard !wanted.isEmpty || !turned.isEmpty, let schematic = files["schematic"] else { return [] }
        var warnings = [String]()
        let sheets = (schematic["sheets"] as? JSONDictionary ?? [:]).compactMap { id, value in (value as? JSONDictionary).map { (id, $0) } }
            .sorted { ($0.1.int("index") ?? 0, $0.0) < ($1.1.int("index") ?? 0, $1.0) }
        for (_, sheet) in sheets {
            for (instanceID, value) in (sheet["symbols"] as? JSONDictionary ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let symbol = value as? JSONDictionary, let componentID = symbol.string("component")?.lowercased(),
                      let gateID = symbol.string("gate")?.lowercased(),
                      (symbol.string("pin_display_mode") ?? "selected_only") == "custom_only" else { continue }
                var pins = wanted[componentID] ?? [:]
                if turned.contains(instanceID.lowercased()) {
                    for (path, value) in components()[componentID]?.dictionary("alt_pins") ?? [:] {
                        guard let entry = value as? JSONDictionary, !(entry["pin_names"] as? [Any] ?? []).isEmpty,
                              !(entry.bool("use_custom_name") == true && !(entry.string("custom_name") ?? "").isEmpty) else { continue }
                        pins[path.lowercased()] = pinName(path.lowercased(), componentID: componentID)
                    }
                }
                let hidden = pins.filter { $0.key.hasPrefix(gateID + "/") }.values
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                guard !hidden.isEmpty else { continue }
                let refdes = components()[componentID]?.string("refdes") ?? componentID
                let listed = hidden.prefix(8).joined(separator: ", ") + (hidden.count > 8 ? ", … (\(hidden.count) pins)" : "")
                // Among a gate's old alternates, the one this batch just chose
                // is the easiest to miss, so it is named on its own.
                let isTurned = turned.contains(instanceID.lowercased())
                let chosen = isTurned ? (wanted[componentID] ?? [:]).filter { $0.key.hasPrefix(gateID + "/") }.values
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending } : []
                let including = chosen.isEmpty ? ""
                    : ", including \(chosen.prefix(8).joined(separator: ", ")), which this batch chose"
                warnings.append("\(refdes)'s symbol \(instanceID) on sheet \(sheet.int("index") ?? 0) (\(sheet.string("name") ?? "")) "
                    + "shows pin names custom_only, so it \(isTurned ? "now" : "still") draws the primary names for \(listed)\(including). "
                    + "set_symbol_display with symbol_instance \(instanceID) and pin_display_mode selected_only draws the alternates.")
            }
        }
        return warnings
    }

    private func unitPin(_ path: String, componentID: String) throws -> HorizontalDispatchPoolIndex.Pin {
        let pieces = path.split(separator: "/").map(String.init)
        guard pieces.count == 2, let entityID = components()[componentID]?.string("entity"),
              let unitID = pool.entity(entityID)?.gates[pieces[0].lowercased()]?.unitID,
              let pin = pool.unit(unitID)?.pins[pieces[1].lowercased()] else {
            throw HorizontalDispatchError.notFound("Pin \(path) is not in its unit.")
        }
        return pin
    }

    /// An alternate by its whole name, its uuid, or — when only one alternate
    /// has it — one of the "/"-separated names it combines.
    private func alternate(_ reference: String, of pin: HorizontalDispatchPoolIndex.Pin, pin label: String) throws -> HorizontalUnitPinAlternateName {
        if let whole = pin.alternates.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame || $0.id.lowercased() == reference.lowercased() }) {
            return whole
        }
        let partial = pin.alternates.filter { alternate in
            alternate.name.split(separator: "/").contains { $0.caseInsensitiveCompare(reference) == .orderedSame }
        }
        if partial.count == 1 { return partial[0] }
        let choices = pin.alternates.map(\.name).sorted()
        guard !choices.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(label) has no alternates; custom_name gives it a name of your own.")
        }
        if partial.count > 1 {
            throw HorizontalDispatchError.ambiguous("\(reference) is part of \(partial.count) alternates of \(label); name one whole.",
                                                    candidates: partial.map(\.name).sorted())
        }
        throw HorizontalDispatchError.invalidParams("\(label) has no alternate \(reference). It offers: \(choices.joined(separator: ", ")).")
    }

    // MARK: - Pins

    /// Resolves the `pin` parameter to Horizon's `gate uuid/pin uuid` key.
    /// A `gate` parameter narrows the search to one gate.
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
        let only = params.string("gate") == nil ? nil : try gate(params, componentID: componentID).id
        return try pinPath(reference, of: entity, gate: only, owner: component.string("refdes") ?? componentID)
    }

    /// A pin of an entity by name or uuid, as Horizon's `gate uuid/pin uuid`.
    ///
    /// The whole reference is tried as a pin name or uuid first, because pin
    /// names carry slashes of their own — `PA13(JTMS/SWDIO)`, `VSSA/VREF-` —
    /// and only then split as gate/pin, the gate by name, suffix or uuid.
    /// `owner` names the part in messages.
    private func pinPath(_ reference: String, of entity: HorizontalDispatchPoolIndex.Entity, gate only: String? = nil,
                         owner: String) throws -> String {
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
                "Pin \(reference) is on \(matches.count) gates of \(owner) (\(entity.name)); pass \"gate\" or name it as gate/pin."
            )
        }
        if !duplicated.isEmpty {
            throw HorizontalDispatchError.ambiguous(
                "More than one pin of \(owner) is called \(reference); name it by pin uuid. get_component lists them.",
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
            "No pin \(reference) on \(owner) (\(entity.name))\(only == nil ? "" : " gate \(entity.gates[only!]?.name ?? only!)"). Pins: \(listed)."
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

    /// The drawn symbols an op names: one `symbol_instance`, or a
    /// component's — only one gate's when `gate` is given.
    private func symbolTargets(_ params: JSONDictionary) throws -> [(sheet: String, id: String, json: JSONDictionary)] {
        if let instance = params.string("symbol_instance") {
            let targets = try symbolInstances().filter { $0.id.caseInsensitiveCompare(instance) == .orderedSame }
            guard !targets.isEmpty else { throw HorizontalDispatchError.notFound("No symbol instance \(instance). list_symbols returns them.") }
            return targets
        }
        let componentID = try componentID(params)
        let gateID = params.string("gate") == nil ? nil : try gate(params, componentID: componentID).id
        let targets = try symbolInstances().filter {
            $0.json.string("component")?.lowercased() == componentID
                && (gateID == nil || $0.json.string("gate")?.lowercased() == gateID)
        }
        guard !targets.isEmpty else { throw HorizontalDispatchError.notFound("No symbol for \(componentID) is on a sheet.") }
        return targets
    }

    private func setSymbolDisplay(_ params: JSONDictionary) throws -> JSONDictionary {
        guard params["pin_display_mode"] != nil || params["display_all_pads"] != nil else {
            throw HorizontalDispatchError.invalidParams("set_symbol_display needs pin_display_mode or display_all_pads.")
        }
        let targets = try symbolTargets(params)
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

    /// Horizon's Edit Custom Value: the symbol's `custom_value`, stored
    /// trimmed and only when there is one, as `SchematicSymbol::serialize`
    /// writes it.
    private func setCustomValue(_ params: JSONDictionary) throws -> JSONDictionary {
        guard params.keys.contains("custom_value") else {
            throw HorizontalDispatchError.invalidParams("set_custom_value needs custom_value: the text, or \"\" or null to clear it.")
        }
        guard params["symbol_instance"] == nil || (params["component"] == nil && params["gate"] == nil) else {
            throw HorizontalDispatchError.invalidParams("Name a symbol_instance, or a component and optionally a gate, not both.")
        }
        let value = HorizontalSymbolCustomValue.normalized(params["custom_value"] as? String)
        let targets = try symbolTargets(params)
        for target in targets {
            try updateSheet(target.sheet) { sheet in
                var symbols = sheet.dictionaryMap("symbols")
                guard var item = symbols[target.id] else { return }
                if let value {
                    item["custom_value"] = value
                } else {
                    item.removeValue(forKey: "custom_value")
                }
                symbols[target.id] = item
                sheet["symbols"] = symbols
            }
        }
        return ["symbol_instances": targets.map(\.id).sorted(), "custom_value": value.map { $0 as Any } ?? NSNull()]
    }

    /// Horizon's Smash and Unsmash, on the symbols named or with `board` on
    /// the component's package. Smashing makes sheet (board) texts the symbol
    /// (package) owns, from the pool's, where it drew them; unsmashing
    /// deletes them. Either leaves a symbol naming only texts its sheet has,
    /// as Horizon prunes the list when it loads.
    private func smash(_ params: JSONDictionary, smashing: Bool) throws -> JSONDictionary {
        let op = smashing ? "smash" : "unsmash"
        if params.bool("board") == true {
            guard params["symbol_instance"] == nil, params["gate"] == nil else {
                throw HorizontalDispatchError.invalidParams("\(op) with board takes a component: its package has no gates or symbol instances.")
            }
            return try smashPackage(componentID(params), smashing: smashing)
        }
        guard params["symbol_instance"] == nil || (params["component"] == nil && params["gate"] == nil) else {
            throw HorizontalDispatchError.invalidParams("Name a symbol_instance, or a component and optionally a gate, not both.")
        }
        var changed = [String](), unchanged = [String](), made = [String](), removed = [String]()
        for target in try symbolTargets(params) {
            try updateSheet(target.sheet) { sheet in
                var symbols = sheet.dictionaryMap("symbols")
                guard var item = symbols[target.id] else { return }
                var texts = sheet["texts"] as? JSONDictionary ?? [:]
                let listed = item["texts"] as? [String] ?? []
                let keys = Dictionary(texts.keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
                let present = listed.compactMap { keys[$0.lowercased()] }
                let isSmashed = item.bool("smashed") == true
                if smashing, isSmashed, !present.isEmpty {
                    guard present != listed else {
                        unchanged.append(target.id)
                        return
                    }
                    item["texts"] = present
                } else if smashing {
                    guard let symbolID = item.string("symbol"), let poolSymbol = pool.symbol(symbolID) else {
                        throw HorizontalDispatchError.notFound(
                            "The project pool has no symbol \(item.string("symbol") ?? "") for \(target.id) to take its texts from.")
                    }
                    var ids = [String]()
                    for text in HorizontalSchematic.smashedTexts(poolSymbol: poolSymbol, placement: item.dictionary("placement")) {
                        let id = UUID().uuidString.lowercased()
                        texts[id] = text
                        ids.append(id)
                    }
                    item["smashed"] = true
                    item["texts"] = ids
                    made += ids
                } else {
                    guard isSmashed || !listed.isEmpty else {
                        unchanged.append(target.id)
                        return
                    }
                    for key in present where (texts[key] as? JSONDictionary)?.bool("from_smash") == true {
                        texts.removeValue(forKey: key)
                        removed.append(key)
                    }
                    item["smashed"] = false
                    item["texts"] = [String]()
                }
                changed.append(target.id)
                symbols[target.id] = item
                sheet["symbols"] = symbols
                sheet["texts"] = texts
            }
        }
        var result: JSONDictionary = ["symbol_instances": changed.sorted()]
        if !unchanged.isEmpty { result["unchanged"] = unchanged.sorted() }
        if smashing { result["texts"] = made } else { result["texts_removed"] = removed.sorted() }
        return result
    }

    /// Smash and Unsmash on a component's package: its silkscreen texts, as
    /// Horizon's `Board::smash_package` takes them.
    private func smashPackage(_ componentID: String, smashing: Bool) throws -> JSONDictionary {
        var result: JSONDictionary = [:]
        try updateBoard { board in
            var packages = board["packages"] as? JSONDictionary ?? [:]
            guard let key = packages.keys.sorted().first(where: {
                (packages[$0] as? JSONDictionary)?.string("component")?.lowercased() == componentID
            }), var package = packages[key] as? JSONDictionary else {
                throw HorizontalDispatchError.notFound("\(componentID) has no package on the board; place_component places it.")
            }
            var texts = board["texts"] as? JSONDictionary ?? [:]
            let listed = package["texts"] as? [String] ?? []
            let keys = Dictionary(texts.keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            let present = listed.compactMap { keys[$0.lowercased()] }
            let isSmashed = package.bool("smashed") == true
            result["package"] = key
            if smashing, isSmashed, !present.isEmpty {
                guard present != listed else {
                    result["unchanged"] = true
                    return
                }
                package["texts"] = present
                result["texts"] = [String]()
            } else if smashing {
                let partID = components()[componentID]?.string("part")
                guard let poolPackage = package.string("alternate_package").flatMap({ pool.package($0) })
                    ?? partID.flatMap({ pool.package(forPart: $0) }) else {
                    throw HorizontalDispatchError.notFound("The project pool has no package for \(componentID) to take its texts from.")
                }
                var ids = [String]()
                for text in HorizontalSmash.boardTexts(package: poolPackage, boardPackage: package, nInnerLayers: board.int("n_inner_layers") ?? 0) {
                    let id = UUID().uuidString.lowercased()
                    texts[id] = text
                    ids.append(id)
                }
                package["smashed"] = true
                package["texts"] = ids
                result["texts"] = ids
            } else {
                guard isSmashed || !listed.isEmpty else {
                    result["unchanged"] = true
                    return
                }
                var removed = [String]()
                for key in present where (texts[key] as? JSONDictionary)?.bool("from_smash") == true {
                    texts.removeValue(forKey: key)
                    removed.append(key)
                }
                package["smashed"] = false
                package["texts"] = [String]()
                result["texts_removed"] = removed.sorted()
            }
            packages[key] = package
            board["packages"] = packages
            board["texts"] = texts
        }
        return result
    }

    /// Moves symbols with what belongs only to them. A junction belongs to
    /// them when its wiring serves no part they leave behind: an island of
    /// wiring that reaches only their pins (and labels or power symbols) goes
    /// whole; in wiring that also reaches pins that stay, so do the dead-end
    /// runs hanging off it toward their pins, back to where they branch, and
    /// the branch point stays. Labels and power symbols stand on junctions,
    /// and wires end on pins and junctions, so they follow; a wire between a
    /// junction that moves and one that stays stretches. Onto another sheet,
    /// such a wire can't follow, and is cut.
    private func moveSymbols(_ params: JSONDictionary) throws -> JSONDictionary {
        let references = params["symbols"] as? [String] ?? []
        let explicitSheet = params["sheet"] == nil ? nil : try sheetID(params)
        var instances = [(sheet: String, id: String, json: JSONDictionary)]()
        for reference in references {
            let byID = try symbolInstances().filter { $0.id.caseInsensitiveCompare(reference) == .orderedSame && (explicitSheet == nil || $0.sheet == explicitSheet) }
            if !byID.isEmpty { instances += byID; continue }
            let component = try componentID(reference: reference)
            let drawn = try symbolInstances().filter { $0.json.string("component")?.lowercased() == component && (explicitSheet == nil || $0.sheet == explicitSheet) }
            guard !drawn.isEmpty else {
                throw HorizontalDispatchError.notFound("\(reference) has no symbol\(explicitSheet == nil ? "" : " on that sheet") to move.")
            }
            instances += drawn
        }
        let sheets = Set(instances.map(\.sheet))
        guard sheets.count == 1, let source = sheets.first else {
            throw HorizontalDispatchError.invalidParams("The symbols are on \(sheets.count) sheets; pass sheet, or move each sheet's on its own.")
        }
        let target = params["to_sheet"] == nil ? source : try sheetID(["sheet": params["to_sheet"]!])
        let dx = Self.nanometres(params.double("dx_mm") ?? 0), dy = Self.nanometres(params.double("dy_mm") ?? 0)
        guard let sheet = try sheetsInOrder().first(where: { $0.id == source })?.json else {
            throw HorizontalDispatchError.notFound("No sheet \(source).")
        }
        let moved = Set(instances.map { $0.id.lowercased() })
        let junctionKeys = Dictionary(sheet.dictionaryMap("junctions").keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let lines = sheet.dictionaryMap("net_lines")

        // The wiring as a graph of junctions, with what each touches.
        var neighbours = [String: Set<String>]()
        var touchesMoved = Set<String>(), anchored = Set<String>()
        func kind(_ end: JSONDictionary?) -> (junction: String?, moved: Bool) {
            guard let end else { return (nil, false) }
            if let junction = end.string("junc")?.lowercased() { return (junction, false) }
            if let pin = end.string("pin")?.lowercased(), let symbol = pin.split(separator: "/").first.map(String.init) {
                return (nil, moved.contains(symbol))
            }
            return (nil, false)
        }
        for line in lines.values {
            let a = kind(line.dictionary("from")), b = kind(line.dictionary("to"))
            for (this, other) in [(a, b), (b, a)] {
                guard let junction = this.junction else { continue }
                neighbours[junction, default: []].formUnion([])
                if let next = other.junction { neighbours[junction, default: []].insert(next) }
                else if other.moved { touchesMoved.insert(junction) }
                else { anchored.insert(junction) }
            }
        }
        // A bus label or ripper, or a net tie, holds its junction where it is.
        for key in ["bus_labels", "bus_rippers"] {
            for mark in sheet.dictionaryMap(key).values { if let junction = mark.string("junction")?.lowercased() { anchored.insert(junction) } }
        }
        for tie in sheet.dictionaryMap("net_ties").values {
            for end in ["from", "to"] { if let junction = tie.string(end)?.lowercased() { anchored.insert(junction) } }
        }
        var carried = Set((params["junctions"] as? [String] ?? []).map { $0.lowercased() })
        for junction in carried where junctionKeys[junction] == nil {
            throw HorizontalDispatchError.notFound("No junction \(junction) on the sheet the symbols are on.")
        }
        var seen = Set<String>()
        for start in neighbours.keys.sorted() where !seen.contains(start) {
            var island = Set<String>(), pending = [start]
            while let node = pending.popLast() {
                guard island.insert(node).inserted else { continue }
                pending.append(contentsOf: neighbours[node] ?? [])
            }
            seen.formUnion(island)
            guard !island.isDisjoint(with: touchesMoved) else { continue }
            guard !island.isDisjoint(with: anchored) else { carried.formUnion(island); continue }
            // Peel the dead ends back to the wiring that joins what stays.
            var degree = island.reduce(into: [String: Int]()) { $0[$1] = neighbours[$1]?.intersection(island).count ?? 0 }
            var peeled = Set<String>(), leaves = island.filter { (degree[$0] ?? 0) <= 1 && !anchored.contains($0) }.sorted()
            while let leaf = leaves.popLast() {
                guard peeled.insert(leaf).inserted else { continue }
                for next in neighbours[leaf] ?? [] where island.contains(next) && !peeled.contains(next) {
                    degree[next, default: 0] -= 1
                    if degree[next, default: 0] <= 1, !anchored.contains(next) { leaves.append(next) }
                }
            }
            var branchSeen = Set<String>()
            for root in peeled.sorted() where !branchSeen.contains(root) {
                var branch = Set<String>(), stack = [root]
                while let node = stack.popLast() {
                    guard peeled.contains(node), branch.insert(node).inserted else { continue }
                    stack.append(contentsOf: neighbours[node] ?? [])
                }
                branchSeen.formUnion(branch)
                if !branch.isDisjoint(with: touchesMoved) { carried.formUnion(branch) }
            }
        }

        func movedEnd(_ end: JSONDictionary?) -> Bool {
            let end = kind(end)
            return end.moved || end.junction.map(carried.contains) == true
        }
        let symbolTexts = Set(instances.flatMap { ($0.json["texts"] as? [String] ?? []).map { $0.lowercased() } })
        let texts = symbolTexts.union((params["texts"] as? [String] ?? []).map { $0.lowercased() })
        let sheetTextKeys = Set(sheet.dictionaryMap("texts").keys.map { $0.lowercased() })
        for text in texts where !sheetTextKeys.contains(text) {
            throw HorizontalDispatchError.notFound("No text \(text) on the sheet the symbols are on.")
        }
        func shifted(_ point: Any?) -> [Int]? {
            guard let point = point as? [Any], point.count == 2 else { return nil }
            return [Int(JSONHelper.doubleValue(point[0])) + dx, Int(JSONHelper.doubleValue(point[1])) + dy]
        }
        func shiftPlacement(_ item: inout JSONDictionary) {
            var placement = item.dictionary("placement") ?? ["angle": 0, "mirror": false, "shift": [0, 0]]
            placement["shift"] = shifted(placement["shift"]) ?? [dx, dy]
            item["placement"] = placement
        }
        var carriedLines = [String](), stretched = [String](), cut = [JSONDictionary]()
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet, block: block)
        for (id, line) in lines {
            let a = movedEnd(line.dictionary("from")), b = movedEnd(line.dictionary("to"))
            if a && b { carriedLines.append(id) }
            else if a || b {
                guard target != source else { stretched.append(id); continue }
                // The end that goes, named as a reply names a wire end.
                let goes = a ? line.dictionary("from") : line.dictionary("to")
                var end: JSONDictionary = ["net_line": id]
                if let net = goes.flatMap({ connectivity.net(at: $0) }) ?? line.string("net") {
                    end["net"] = net
                    end["net_name"] = nets()[net.lowercased()]?.string("name") ?? ""
                }
                if let junction = goes?.string("junc") { end["junction"] = junctionKeys[junction.lowercased()] ?? junction }
                if let pin = goes?.string("pin") {
                    let pieces = pin.lowercased().split(separator: "/").map(String.init)
                    if let instance = instances.first(where: { $0.id.lowercased() == pieces.first }),
                       let component = instance.json.string("component")?.lowercased(), let gate = instance.json.string("gate"), pieces.count == 2 {
                        end["pin"] = "\(components()[component]?.string("refdes") ?? component).\(pinName("\(gate.lowercased())/\(pieces[1])", componentID: component))"
                    }
                }
                if let position = wireEndPosition(goes, sheet: sheet) {
                    end["x_mm"] = HorizontalDispatchJSON.mm(position.x + Double(dx))
                    end["y_mm"] = HorizontalDispatchJSON.mm(position.y + Double(dy))
                }
                cut.append(end)
            }
        }
        let marks = ["net_labels", "power_symbols"].reduce(into: [String: [String]]()) { result, key in
            result[key] = sheet.dictionaryMap(key).filter { $0.value.string("junction").map { carried.contains($0.lowercased()) } == true }.keys.sorted()
        }
        let ties = sheet.dictionaryMap("net_ties").filter { _, tie in
            ["from", "to"].allSatisfy { tie.string($0).map { carried.contains($0.lowercased()) } == true }
        }.keys.sorted()

        if target == source {
            try updateSheet(source) { sheet in
                var symbols = sheet.dictionaryMap("symbols")
                for key in symbols.keys where moved.contains(key.lowercased()) { shiftPlacement(&symbols[key]!) }
                sheet["symbols"] = symbols
                var junctions = sheet.dictionaryMap("junctions")
                for key in junctions.keys where carried.contains(key.lowercased()) {
                    let position = shifted(junctions[key]?["position"])
                    junctions[key]?["position"] = position
                }
                sheet["junctions"] = junctions
                var textMap = sheet.dictionaryMap("texts")
                for key in textMap.keys where texts.contains(key.lowercased()) { shiftPlacement(&textMap[key]!) }
                sheet["texts"] = textMap
            }
        } else {
            guard let destination = try sheetsInOrder().first(where: { $0.id == target })?.json else {
                throw HorizontalDispatchError.notFound("No sheet \(target).")
            }
            for (key, ids) in [("symbols", moved), ("junctions", carried), ("texts", texts)] {
                let clash = Set(destination.dictionaryMap(key).keys.map { $0.lowercased() }).intersection(ids)
                guard clash.isEmpty else { throw HorizontalDispatchError.invalidParams("The other sheet already has \(key) \(clash.sorted().joined(separator: ", ")).") }
            }
            var taken = JSONDictionary()
            try updateSheet(source) { sheet in
                func take(_ key: String, _ ids: Set<String>, _ transform: (inout JSONDictionary) -> Void = { _ in }) {
                    var map = sheet.dictionaryMap(key), out = [String: JSONDictionary]()
                    for id in map.keys where ids.contains(id.lowercased()) {
                        var item = map.removeValue(forKey: id)!
                        transform(&item)
                        out[id] = item
                    }
                    sheet[key] = map
                    taken[key] = out
                }
                take("symbols", moved, shiftPlacement)
                take("junctions", carried) { $0["position"] = shifted($0["position"]) }
                take("texts", texts, shiftPlacement)
                take("net_lines", Set(carriedLines.map { $0.lowercased() }))
                take("net_labels", Set(marks["net_labels"]!.map { $0.lowercased() }))
                take("power_symbols", Set(marks["power_symbols"]!.map { $0.lowercased() }))
                take("net_ties", Set(ties.map { $0.lowercased() }))
                // What reached across is cut.
                var remaining = sheet.dictionaryMap("net_lines")
                for end in cut { if let id = end.string("net_line") { remaining.removeValue(forKey: id) } }
                sheet["net_lines"] = remaining
            }
            try updateSheet(target) { sheet in
                for (key, value) in taken {
                    var map = sheet.dictionaryMap(key)
                    for (id, item) in value as? [String: JSONDictionary] ?? [:] { map[id] = item }
                    sheet[key] = map
                }
            }
            // A junction the cut wires leave holding nothing goes.
            let farEnds = cut.compactMap { $0.string("net_line") }.flatMap { lines[$0].map(Self.lineJunctions) ?? [] }
            try collectSheetJunctions(source, candidates: Set(farEnds).subtracting(carried))
        }
        var change: JSONDictionary = ["sheet": source, "symbols": instances.map(\.id).sorted(),
                                      "junctions": carried.compactMap { junctionKeys[$0] }.sorted(),
                                      "net_lines": carriedLines.sorted(), "net_labels": marks["net_labels"]!,
                                      "power_symbols": marks["power_symbols"]!,
                                      "dx_mm": HorizontalDispatchJSON.mm(Double(dx)), "dy_mm": HorizontalDispatchJSON.mm(Double(dy))]
        if !texts.isEmpty { change["texts"] = texts.sorted() }
        if !ties.isEmpty { change["net_ties"] = ties }
        if target != source { change["to_sheet"] = target }
        if !stretched.isEmpty { change["stretched_net_lines"] = stretched.sorted() }
        if !cut.isEmpty {
            change["cut"] = cut.sorted { ($0.string("net_line") ?? "") < ($1.string("net_line") ?? "") }
            change["note"] = "\(cut.count) wire\(cut.count == 1 ? "" : "s") reached wiring that stays on the other sheet and \(cut.count == 1 ? "was" : "were") cut; each cut end is given with its net and where it is now. terminate_pin, or place_net_label there with a wire to it, joins it to its net on this sheet."
        }
        return change
    }

    /// What a sheet holds that Move to other sheet can carry, by collection.
    static let otherSheetCollections = ["symbols", "block_symbols", "junctions", "net_lines", "net_labels", "power_symbols",
                                        "bus_labels", "bus_rippers", "net_ties", "texts", "lines", "arcs", "pictures"]

    /// Horizon's Move to other sheet (`ImpSchematic::handle_move_to_other_sheet`):
    /// the selection grows until it holds everything drawn connected to it,
    /// then all of it changes sheet whole, ids and all, so no wire is cut.
    private func moveToOtherSheet(_ params: JSONDictionary) throws -> JSONDictionary {
        let references = params["items"] as? [String] ?? []
        guard params["to_sheet"] != nil else {
            throw HorizontalDispatchError.invalidParams("move_to_other_sheet needs to_sheet: the sheet to move onto.")
        }
        let explicitSheet = params["sheet"] == nil ? nil : try sheetID(params)
        let pages = try sheetsInOrder()
        // Each id, by what it is and where.
        var found = [(sheet: String, key: String, id: String)]()
        for reference in references {
            let wanted = reference.lowercased()
            let hits = pages.filter { explicitSheet == nil || $0.id == explicitSheet }.flatMap { page in
                Self.otherSheetCollections.compactMap { key in
                    page.json.dictionaryMap(key).keys.contains { $0.lowercased() == wanted } ? (page.id, key, wanted) : nil
                }
            }
            if !hits.isEmpty { found += hits; continue }
            let component = try componentID(reference: reference)
            let drawn = try symbolInstances().filter {
                $0.json.string("component")?.lowercased() == component && (explicitSheet == nil || $0.sheet == explicitSheet)
            }
            guard !drawn.isEmpty else {
                throw HorizontalDispatchError.notFound("Nothing called \(reference) is drawn\(explicitSheet == nil ? "" : " on that sheet").")
            }
            found += drawn.map { ($0.sheet, "symbols", $0.id.lowercased()) }
        }
        let sheets = Set(found.map(\.sheet))
        guard sheets.count == 1, let source = sheets.first else {
            throw HorizontalDispatchError.invalidParams("The items are on \(sheets.count) sheets; pass sheet, or move each sheet's on its own.")
        }
        let target = try sheetID(["sheet": params["to_sheet"]!])
        guard target != source else {
            throw HorizontalDispatchError.invalidParams("The items are on that sheet already; move_to_other_sheet takes them to another.")
        }
        guard let sheet = pages.first(where: { $0.id == source })?.json, let destination = pages.first(where: { $0.id == target })?.json else {
            throw HorizontalDispatchError.notFound("No sheet \(target).")
        }

        // Grow the selection as Horizon does, both ways, until it stops.
        var selected = Dictionary(grouping: found, by: \.key).mapValues { Set($0.map(\.id)) }
        func has(_ key: String, _ id: String?) -> Bool { id.map { selected[key]?.contains($0.lowercased()) == true } ?? false }
        func owner(_ path: String?) -> String? { path?.lowercased().split(separator: "/").first.map(String.init) }
        let maps = Dictionary(uniqueKeysWithValues: Self.otherSheetCollections.map { ($0, sheet.dictionaryMap($0)) })
        func lowered(_ key: String) -> [(String, JSONDictionary)] { maps[key, default: [:]].map { ($0.key.lowercased(), $0.value) } }
        var grown = true
        while grown {
            var adding = [String: Set<String>]()
            func add(_ key: String, _ id: String?) { if let id { adding[key, default: []].insert(id.lowercased()) } }
            // A mark on a junction and the junction go together.
            for key in ["net_labels", "bus_labels", "power_symbols", "bus_rippers"] {
                for (id, item) in lowered(key) {
                    if has(key, id) { add("junctions", item.string("junction")) }
                    if has("junctions", item.string("junction")) { add(key, id) }
                }
            }
            for (id, tie) in lowered("net_ties") {
                if has("net_ties", id) { add("junctions", tie.string("from")); add("junctions", tie.string("to")) }
                if has("junctions", tie.string("from")) || has("junctions", tie.string("to")) { add("net_ties", id) }
            }
            for (id, line) in lowered("net_lines") {
                for end in [line.dictionary("from"), line.dictionary("to")].compactMap({ $0 }) {
                    let ends: [(String, String?)] = [("junctions", end.string("junc")), ("bus_rippers", end.string("bus_ripper")),
                                                     ("symbols", owner(end.string("pin"))), ("block_symbols", owner(end.string("port")))]
                    for (key, endID) in ends where endID != nil {
                        if has("net_lines", id) { add(key, endID) }
                        if has(key, endID) { add("net_lines", id) }
                    }
                }
            }
            for key in ["lines", "arcs"] {
                for (id, item) in lowered(key) {
                    let points = ["from", "to", "center"].compactMap { item.string($0) }
                    if has(key, id) { points.forEach { add("junctions", $0) } }
                    if points.contains(where: { has("junctions", $0) }) { add(key, id) }
                }
            }
            for (id, symbol) in lowered("symbols") where has("symbols", id) {
                (symbol["texts"] as? [String] ?? []).forEach { add("texts", $0) }
            }
            grown = false
            for (key, ids) in adding {
                let known = Set(maps[key, default: [:]].keys.map { $0.lowercased() })
                let before = selected[key, default: []].count
                selected[key, default: []].formUnion(ids.intersection(known))
                if selected[key, default: []].count != before { grown = true }
            }
        }

        for (key, ids) in selected {
            let clash = Set(destination.dictionaryMap(key).keys.map { $0.lowercased() }).intersection(ids)
            guard clash.isEmpty else { throw HorizontalDispatchError.invalidParams("The other sheet already has \(key) \(clash.sorted().joined(separator: ", ")).") }
        }
        let dx = Self.nanometres(params.double("dx_mm") ?? 0), dy = Self.nanometres(params.double("dy_mm") ?? 0)
        func shifted(_ point: Any?) -> [Int]? {
            guard let point = point as? [Any], point.count == 2 else { return nil }
            return [Int(JSONHelper.doubleValue(point[0])) + dx, Int(JSONHelper.doubleValue(point[1])) + dy]
        }
        var taken = [String: [String: JSONDictionary]]()
        try updateSheet(source) { sheet in
            for (key, ids) in selected {
                var map = sheet.dictionaryMap(key), out = [String: JSONDictionary]()
                for id in map.keys where ids.contains(id.lowercased()) {
                    var item = map.removeValue(forKey: id)!
                    if dx != 0 || dy != 0 {
                        if key == "junctions" {
                            item["position"] = shifted(item["position"])
                        } else if var placement = item.dictionary("placement") {
                            placement["shift"] = shifted(placement["shift"]) ?? [dx, dy]
                            item["placement"] = placement
                        }
                    }
                    out[id] = item
                }
                sheet[key] = map
                taken[key] = out
            }
        }
        try updateSheet(target) { sheet in
            for (key, items) in taken {
                var map = sheet.dictionaryMap(key)
                for (id, item) in items { map[id] = item }
                sheet[key] = map
            }
        }
        let named = Set(found.map { "\($0.key)/\($0.id)" })
        var moved = JSONDictionary()
        var pulledIn = 0
        for (key, items) in taken where !items.isEmpty {
            moved[key] = items.keys.sorted()
            pulledIn += items.keys.filter { !named.contains("\(key)/\($0.lowercased())") }.count
        }
        var change: JSONDictionary = ["sheet": source, "to_sheet": target, "moved": moved,
                                      "count": taken.values.reduce(0) { $0 + $1.count }, "pulled_in": pulledIn]
        if dx != 0 || dy != 0 {
            change["dx_mm"] = HorizontalDispatchJSON.mm(Double(dx))
            change["dy_mm"] = HorizontalDispatchJSON.mm(Double(dy))
        }
        return change
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
        // Horizon's disconnect_symbol, as the app's delete does: each wire
        // ending on a pin of the symbol ends instead on a junction where the
        // pin was, one per pin, on the wire's net.
        var reEnded = 0, removedLines = 0
        for instance in doomed {
            try updateSheet(instance.sheet) { sheet in
                let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet, block: block)
                var netLines = sheet.dictionaryMap("net_lines")
                var junctions = sheet.dictionaryMap("junctions")
                var pinJunctions = [String: String]()
                for (id, line) in sheet.dictionaryMap("net_lines") {
                    var line = line
                    var changed = false, stranded = false
                    for end in ["from", "to"] {
                        guard let endpoint = line.dictionary(end), let pin = endpoint.string("pin")?.lowercased(),
                              pin.split(separator: "/").first.map(String.init) == instance.id.lowercased() else { continue }
                        let junction: String
                        if let existing = pinJunctions[pin] {
                            junction = existing
                        } else if let position = wireEndPosition(endpoint, sheet: sheet) {
                            junction = UUID().uuidString.lowercased()
                            var json: JSONDictionary = ["position": [Int(position.x.rounded()), Int(position.y.rounded())]]
                            if let net = connectivity.net(at: endpoint) ?? line.string("net") { json["net"] = net }
                            junctions[junction] = json
                            pinJunctions[pin] = junction
                        } else {
                            // No drawing says where the pin was: the wire goes.
                            stranded = true
                            continue
                        }
                        line[end] = ["junc": junction, "pin": NSNull(), "port": NSNull(), "bus_ripper": NSNull()] as JSONDictionary
                        changed = true
                    }
                    if stranded {
                        netLines.removeValue(forKey: id)
                        removedLines += 1
                    } else if changed {
                        netLines[id] = line
                        reEnded += 1
                    }
                }
                var symbols = sheet["symbols"] as? JSONDictionary ?? [:]
                symbols.removeValue(forKey: instance.id)
                sheet["symbols"] = symbols
                sheet["net_lines"] = netLines
                sheet["junctions"] = junctions
            }
        }
        // ...and its gate leaves every net and no-connect mark, so placed
        // again it starts unconnected; the component stays for its other
        // gates. A gate that isn't drawn keeps what it has.
        let gates = Set(doomed.compactMap { $0.json.string("gate")?.lowercased() })
        let connections = components()[componentID]?.dictionary("connections") ?? [:]
        let leaving = connections.keys.filter { gates.contains(String($0.lowercased().split(separator: "/").first ?? "")) }
        let disconnected = leaving.map { pinName($0.lowercased(), componentID: componentID) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if !leaving.isEmpty {
            try updateComponent(componentID) { component in
                var connections = component["connections"] as? JSONDictionary ?? [:]
                for key in leaving { connections.removeValue(forKey: key) }
                component["connections"] = connections
            }
            touchedPins.formUnion(leaving.map { "\(componentID)|\($0.lowercased())" })
        }
        var removed: JSONDictionary = ["symbols": doomed.count, "net_lines": reEnded + removedLines, "net_lines_re_ended": reEnded]
        if !disconnected.isEmpty { removed["disconnected"] = disconnected }
        return removed
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
        /// An instance's port on no net yet, which the wire connects.
        var port: (instance: String, net: String)? = nil
        /// A component's pin on no net yet, which the wire connects.
        var pin: (component: String, path: String)? = nil
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
            let json = Self.pinEndpoint("\(instance.id)/\(pinID)"), identity = "pin/\(instance.id)/\(pinID)"
            guard let connection else {
                // On no net yet: the wire connects it, as Horizon's wire tool does.
                return WireEnd(sheet: instance.sheet, net: nil, json: json, identity: identity, pin: (component, path))
            }
            guard let net = connection.string("net")?.lowercased(), block.dictionaryMap("nets")[net] != nil
                    || block.dictionaryMap("nets").keys.contains(where: { $0.lowercased() == net }) else {
                throw HorizontalDispatchError.invalidParams("\(refdes) pin \(name) is marked no-connect. Connect it to a net first.")
            }
            return WireEnd(sheet: instance.sheet, net: net, json: json, identity: identity)
        }
        if endpoint.string("kind") == "port" {
            return try portWireEnd(endpoint, sheet: selected)
        }
        guard endpoint.string("kind") == "junction", Set(endpoint.keys) == ["kind", "junction"],
              let id = endpoint.string("junction")?.lowercased() else {
            throw HorizontalDispatchError.invalidParams("An endpoint is {kind: pin, symbol, pin}, {kind: pin, component, gate?, pin}, {kind: port, instance, port} or {kind: junction, junction}.")
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

    /// A block instance's port, where its block symbol draws it: on the
    /// port's net, or on none yet — Horizon's wire tool then connects it to
    /// the net the wire brings. A port marked not connected takes no wire.
    private func portWireEnd(_ endpoint: JSONDictionary, sheet selected: String?) throws -> WireEnd {
        guard Set(endpoint.keys).isSubset(of: ["kind", "instance", "port"]),
              let portReference = endpoint.string("port"), !portReference.isEmpty, endpoint.string("instance") != nil else {
            throw HorizontalDispatchError.invalidParams("A port endpoint is {kind: port, instance: <id or refdes>, port: <port net name or uuid>}.")
        }
        let instanceID = try blockInstanceID(endpoint)
        guard let instance = blockInstances()[instanceID] as? JSONDictionary, let usedBlock = instance.string("block") else {
            throw HorizontalDispatchError.notFound("Block instance \(instanceID) names no block.")
        }
        let refdes = instance.string("refdes") ?? instanceID
        let portNet = try blockPortID(portReference, of: usedBlock).lowercased()
        let drawn = try blockSymbolInstances().filter {
            $0.json.string("block_instance")?.lowercased() == instanceID.lowercased() && (selected == nil || selected == $0.sheet)
        }
        guard let symbol = drawn.first else {
            throw HorizontalDispatchError.notFound("\(refdes) has no block symbol\(selected == nil ? "" : " on that sheet") to wire to; place_block_symbol it first.")
        }
        guard let portID = HorizontalBlockSymbolPortID.uuid(forNet: portNet) else {
            throw HorizontalDispatchError.invalidParams("Port net \(portNet) is not a uuid.")
        }
        let portName = (try? blockFile(usedBlock))?.dictionaryMap("nets").first { $0.key.lowercased() == portNet }?.value.string("name") ?? portNet
        if let path = knownBlock(usedBlock)?.symbolFilename, !path.isEmpty, let symbolJSON = try projectFile(path),
           !symbolJSON.dictionaryMap("ports").keys.contains(where: { $0.lowercased() == portID }) {
            throw HorizontalDispatchError.invalidParams("\(refdes)'s block symbol does not draw port \(portName), so there is nothing to wire to; place_block_port it on the block's symbol.")
        }
        let json: JSONDictionary = ["bus_ripper": NSNull(), "junc": NSNull(), "pin": NSNull(), "port": "\(symbol.id)/\(portID)"]
        let connection = instance.dictionaryMap("connections").first { $0.key.lowercased() == portNet }?.value
        if let connection {
            guard let net = connection.string("net")?.lowercased() else {
                throw HorizontalDispatchError.invalidParams("\(refdes) port \(portName) is marked not connected; disconnect_block_port it first.")
            }
            return WireEnd(sheet: symbol.sheet, net: net, json: json, identity: "port/\(symbol.id)/\(portID)")
        }
        return WireEnd(sheet: symbol.sheet, net: nil, json: json, identity: "port/\(symbol.id)/\(portID)",
                       port: (instanceID, portNet))
    }

    /// A wire end's `<block symbol>/<port uuid>` as a port endpoint, by the
    /// instance the symbol draws and the port net the uuid is derived from.
    private func portSelector(_ path: String) throws -> JSONDictionary? {
        let pieces = path.split(separator: "/").map { $0.lowercased() }
        guard pieces.count == 2,
              let symbol = try blockSymbolInstances().first(where: { $0.id.lowercased() == pieces[0] }),
              let instanceID = symbol.json.string("block_instance"),
              let usedBlock = (blockInstances().first { $0.key.lowercased() == instanceID.lowercased() }?.value as? JSONDictionary)?.string("block"),
              let portNet = (try? blockFile(usedBlock))?.dictionaryMap("nets").keys.first(where: {
                  HorizontalBlockSymbolPortID.uuid(forNet: $0) == pieces[1]
              }) else {
            return nil
        }
        return ["kind": "port", "instance": instanceID, "port": portNet]
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
        let net: String
        var createdNet: String? = nil
        if let known = start.net ?? end.net {
            net = known
        } else if [start, end].contains(where: { $0.pin != nil || $0.port != nil }) {
            // Two ends on no net: Horizon's wire tool gives them a new net
            // with no name, which a label names later.
            net = try ensureNet(["name": ""]).0
            createdNet = net
        } else {
            throw HorizontalDispatchError.invalidParams("Neither end is on a net. Wire one end to a pin, label or power symbol, or place_junction it on a net.")
        }
        guard (start.net ?? net) == net, (end.net ?? net) == net else {
            throw HorizontalDispatchError.invalidParams("The endpoints are on different nets (\(start.net!), \(end.net!)); a wire joins one net.")
        }
        var adopted = [String]()
        var connectedPorts = [JSONDictionary]()
        var connectedPins = [String]()
        for wireEnd in [start, end] where wireEnd.net == nil {
            if let junction = wireEnd.junction {
                try adoptJunction(junction, sheet: start.sheet, net: net)
                adopted.append(junction)
            }
            if let port = wireEnd.port {
                _ = try connectBlockPort(["instance": port.instance, "port": port.net, "net": net])
                connectedPorts.append(["block_instance": port.instance, "port": port.net])
            }
            if let pin = wireEnd.pin {
                try connect(pin.component, pin: pin.path, to: net)
                connectedPins.append("\(components()[pin.component]?.string("refdes") ?? pin.component).\(pinName(pin.path, componentID: pin.component))")
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
        if !connectedPorts.isEmpty { change["connected_ports"] = connectedPorts }
        if !connectedPins.isEmpty { change["connected_pins"] = connectedPins }
        if let createdNet { change["created_net"] = createdNet }
        return change
    }

    /// place_junction on a junction that is there: it goes to the point, and
    /// the wires, labels and power symbols standing on it with it, since they
    /// name it rather than a place.
    private func moveJunction(_ id: String, on sheet: String, to point: [Int], _ params: JSONDictionary) throws -> JSONDictionary {
        guard let json = try sheetsInOrder().first(where: { $0.id == sheet })?.json,
              let key = json.dictionaryMap("junctions").keys.first(where: { $0.lowercased() == id }) else {
            throw HorizontalDispatchError.notFound("No junction \(id).")
        }
        let connectivity = HorizontalSchematicNetConnectivity(sheet: json, block: block)
        let current = connectivity.net(at: ["junc": key])?.lowercased()
        if params["net"] != nil {
            let net = try netID(params).lowercased()
            guard current == nil || current == net else {
                throw HorizontalDispatchError.invalidParams("Junction \(key) is on \(nets()[current!]?.string("name") ?? current!), not \(params["net"]!); moving it keeps its net.")
            }
        }
        if let other = json.dictionaryMap("junctions").first(where: { $0.key.lowercased() != id && $0.value["position"] as? [Int] == point }) {
            throw HorizontalDispatchError.invalidParams("Junction \(other.key) is already at that point; a wire to it joins the two, or remove_junction one.")
        }
        let from = json.dictionaryMap("junctions")[key]?["position"] as? [Int]
        try updateSheet(sheet) { sheet in
            var junctions = sheet.dictionaryMap("junctions")
            junctions[key]?["position"] = point
            sheet["junctions"] = junctions
        }
        var change: JSONDictionary = ["junction": key, "sheet": sheet, "moved": true, "created": false,
                                      "x_mm": HorizontalDispatchJSON.mm(Double(point[0])), "y_mm": HorizontalDispatchJSON.mm(Double(point[1]))]
        if let net = current { change["net"] = net }
        if let from { change["from_mm"] = [HorizontalDispatchJSON.mm(Double(from[0])), HorizontalDispatchJSON.mm(Double(from[1]))] }
        return change
    }

    private func placeJunction(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_junction needs x_mm and y_mm.")
        }
        let point = [Self.nanometres(x), Self.nanometres(y)]
        // An id naming a junction that is there moves it.
        if let reference = params.string("id")?.lowercased() {
            let explicit = params["sheet"] == nil ? nil : try sheetID(params)
            let holders = try sheetsInOrder().filter { explicit == nil || $0.id == explicit }
                .filter { $0.json.dictionaryMap("junctions").keys.contains { $0.lowercased() == reference } }
            if let holder = holders.first { return try moveJunction(reference, on: holder.id, to: point, params) }
        }
        let sheet = try sheetID(params), net = try netID(params)
        let requested = try editObjectID(params)
        var id = requested
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
        var change: JSONDictionary = ["junction": id, "sheet": sheet, "net": net, "created": created]
        // The id this op was given now means the junction it found, for the
        // rest of the batch and in its handles.
        if !created, params.string("id") != nil, requested != id.lowercased() {
            reusedIDs[requested] = id
            change["reused"] = true
            change["requested_id"] = requested
        }
        return change
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
        } else if let path = otherJSON.string("port"), let selector = try portSelector(path) {
            otherSelector = selector
        } else {
            throw HorizontalDispatchError.unsupported("Retargeting currently requires a pin, port or junction at the opposite end.")
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
        if replacement.net == nil, let port = replacement.port {
            _ = try connectBlockPort(["instance": port.instance, "port": port.net, "net": wireNet])
        }
        try updateSheet(line.0) { sheet in
            var lines = sheet.dictionaryMap("net_lines")
            lines[line.1]?[end] = replacement.json
            sheet["net_lines"] = lines
        }
        var change: JSONDictionary = ["net_line": line.1, "sheet": line.0, "end": end, "net": wireNet]
        if replacement.net == nil, let junction = replacement.junction { change["adopted_junctions"] = [junction] }
        if replacement.net == nil, let port = replacement.port {
            change["connected_ports"] = [["block_instance": port.instance, "port": port.net]]
        }
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
            throw HorizontalDispatchError.invalidParams("pin_map must map pins of the old part to pins of the new one, each a name or gate/pin.")
        }
        let rawMap = params["pin_map"] as? [String: String] ?? [:]
        guard let oldEntityID = component.string("entity"), let oldEntity = pool.entity(oldEntityID) else {
            throw HorizontalDispatchError.notFound("The old entity is missing.")
        }
        /// A gateUUID/pinUUID as it stands, else a pin named as connect names
        /// one: by name or uuid, whole first, then as gate/pin.
        func path(_ reference: String, of entity: HorizontalDispatchPoolIndex.Entity, side: String) throws -> String {
            let pieces = reference.lowercased().split(separator: "/").map(String.init)
            if pieces.count == 2, entity.gates[pieces[0]]?.unitID.flatMap({ pool.unit($0)?.pins[pieces[1]] }) != nil {
                return reference.lowercased()
            }
            do {
                return try pinPath(reference, of: entity, owner: "the \(side) part").lowercased()
            } catch let error as HorizontalDispatchError {
                var error = error
                error.message = "pin_map: " + error.message
                throw error
            }
        }
        var mapping = [String: String]()
        for (oldReference, newReference) in rawMap.sorted(by: { $0.key < $1.key }) {
            let old = try path(oldReference, of: oldEntity, side: "old"), new = try path(newReference, of: targetEntity, side: "new")
            guard mapping[old] == nil else {
                throw HorizontalDispatchError.invalidParams("pin_map names old pin \(oldReference) twice.")
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
            // A part with one gate takes every old gate's pins by name: a
            // supply gate folds into the main one.
            let only = targetEntity.gates.count == 1 ? targetEntity.gates : [:]
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
        // Every pin on a net must have come through one way or the other;
        // name the ones that did not, rather than the first. A no-connect
        // mark (a connection with no net) or a chosen alternate on a pin the
        // new part lacks has nothing to keep, and is dropped as an unmapped
        // pad is.
        let needed = Set((component.dictionary("connections") ?? [:]).filter { ($0.value as? JSONDictionary)?.string("net") != nil }
            .keys.map { $0.lowercased() })
        let unmapped = needed.subtracting(mapping.keys).sorted()
        guard unmapped.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "\(unmapped.count) connected pins have no counterpart by name on the new part: \(unmapped.prefix(40).map { pinName($0, componentID: componentID) }.joined(separator: ", ")). Map them in pin_map, by pin name, e.g. {\"\(unmapped.first.map { pinName($0, componentID: componentID) } ?? "VSSA/VREF-")\": \"<new pin>\"}; nothing was changed."
            )
        }
        var connections = JSONDictionary(), altPins = JSONDictionary()
        var droppedNoConnects = [String](), droppedAlternates = [String]()
        for (key, value) in component.dictionary("connections") ?? [:] {
            guard let new = mapping[key.lowercased()] else {
                guard (value as? JSONDictionary)?.string("net") == nil else {
                    throw HorizontalDispatchError.invalidParams("Connected pin \(key) has no mapping; nothing was changed.")
                }
                droppedNoConnects.append(pinName(key.lowercased(), componentID: componentID))
                continue
            }
            connections[new] = value
        }
        for (key, value) in component.dictionary("alt_pins") ?? [:] {
            guard let new = mapping[key.lowercased()] else {
                droppedAlternates.append(pinName(key.lowercased(), componentID: componentID))
                continue
            }
            altPins[new] = value
        }
        let requestedSymbols = try stringMap(params, key: "symbols")
        guard Set(requestedSymbols.keys).isSubset(of: Set(targetEntity.gates.keys)) else {
            throw HorizontalDispatchError.invalidParams("symbols contains an unknown target gate.")
        }
        var symbolUpdates = [String: (sheet: String, item: JSONDictionary)]()
        var wirePins = [String: String]()
        // Each drawn gate goes to the target gate its pins land on. Where
        // several land on one — a supply gate folding into a single-gate part —
        // the symbol of the one with most pins there draws it, and the others'
        // come off with their wiring; their pins are then the kept symbol's,
        // with no wire to them yet.
        var drawnGates = [(instance: (sheet: String, id: String, json: JSONDictionary), oldGate: String, gate: String, pins: Int)]()
        for instance in try symbolInstances() where instance.json.string("component")?.lowercased() == componentID {
            guard let oldGate = instance.json.string("gate")?.lowercased() else { continue }
            let gateMap = mapping.filter { $0.key.hasPrefix(oldGate + "/") }
            let newGates = Set(gateMap.values.compactMap { $0.split(separator: "/").first.map(String.init) })
            guard newGates.count == 1, let gate = newGates.first else {
                let name = oldEntity.gates[oldGate]?.name ?? oldGate
                throw HorizontalDispatchError.invalidParams(
                    "The drawn gate \(name)'s pins land on \(newGates.count) gates of the new part; each drawn gate's pins have to land on one. "
                        + "Map them with pin_map, or remove_symbol that gate first.")
            }
            drawnGates.append((instance, oldGate, gate, gateMap.count))
        }
        var droppedInstances = Set<String>()
        var foldedPins = [String]()
        var keptGates = [(instance: (sheet: String, id: String, json: JSONDictionary), oldGate: String, gate: String)]()
        for (_, group) in Dictionary(grouping: drawnGates, by: \.gate) {
            let keep = group.max { ($0.pins, $1.instance.id) < ($1.pins, $0.instance.id) }!
            keptGates.append((keep.instance, keep.oldGate, keep.gate))
            for other in group where other.instance.id != keep.instance.id {
                droppedInstances.insert(other.instance.id.lowercased())
                foldedPins += mapping.filter { $0.key.hasPrefix(other.oldGate + "/") }.keys.map { pinName($0, componentID: componentID) }
            }
        }
        let debrisBefore = droppedInstances.isEmpty ? [:] : try debris(onSheetsDrawing: componentID, gate: nil, keep: false)
        for (instance, oldGate, gate) in keptGates.sorted(by: { $0.instance.id < $1.instance.id }) {
            let gateMap = mapping.filter { $0.key.hasPrefix(oldGate + "/") }
            guard let unit = targetEntity.gates[gate]?.unitID else {
                throw HorizontalDispatchError.invalidParams("Target gate \(gate) names no unit, so nothing draws it.")
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
                    if droppedInstances.contains(id.lowercased()) { symbols.removeValue(forKey: id) }
                }
                for (id, line) in lines where ["from", "to"].contains(where: { end in
                    line.dictionary(end)?.string("pin")?.lowercased().split(separator: "/").first.map { droppedInstances.contains(String($0)) } ?? false
                }) {
                    lines.removeValue(forKey: id)
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
        // The same package: every pad stays the pad it was, copper and all,
        // whichever pin the new part puts on it. Pins with several pads (VS+,
        // VS−) can't say which pad is which, and needn't.
        let oldPackage = oldPart.flatMap { poolPart($0.lowercased())?.packageID?.lowercased() }
        var samePackage = 0
        if let oldPackage, oldPackage == target.packageID?.lowercased() {
            let targetIDs = Set(targetPads.compactMap { $0.string("id")?.lowercased() })
            for terminal in oldPads {
                guard let id = terminal.string("id")?.lowercased(), padMapping[id] == nil, targetIDs.contains(id) else { continue }
                padMapping[id] = id
                samePackage += 1
            }
        }
        for terminal in oldPads {
            guard let id = terminal.string("id")?.lowercased(), padMapping[id] == nil,
                  let path = terminal.string("gate_pin_path")?.lowercased(), let newPath = mapping[path] else { continue }
            let matches = targetPads.filter { $0.string("gate_pin_path")?.lowercased() == newPath }
            if matches.count == 1 { padMapping[id] = matches[0].string("id") }
        }
        // A pad whose pin says nothing about where it goes — no pin, or one
        // with no counterpart — goes to the target pad of the same name, when
        // there is one and nothing else took it: pad 3 of a SOIC-8 is pad 3
        // of an MSOP-8.
        let taken = Set(padMapping.values.map { $0.lowercased() })
        var byName = 0
        for terminal in oldPads {
            guard let id = terminal.string("id")?.lowercased(), padMapping[id] == nil,
                  terminal.string("gate_pin_path").map({ mapping[$0.lowercased()] == nil }) ?? true,
                  let name = terminal.string("name"), !name.isEmpty else { continue }
            let matches = targetPads.filter { ($0.string("name") ?? "").caseInsensitiveCompare(name) == .orderedSame }
            guard matches.count == 1, let target = matches[0].string("id")?.lowercased(), !taken.contains(target) else { continue }
            padMapping[id] = target
            byName += 1
        }
        let copper = params.string("copper") ?? "refuse"
        guard ["refuse", "drop"].contains(copper) else {
            throw HorizontalDispatchError.invalidParams("copper must be refuse or drop.")
        }
        var dropped = [String]()
        var underFootprint = [JSONDictionary]()
        if isTopBlock, files["board"] != nil {
            let packageIDs = Set(try board().dictionaryMap("packages").filter { $0.value.string("component")?.lowercased() == componentID }.keys.map { $0.lowercased() })
            // Every routed pad with nowhere to go, named, before anything moves.
            let padNames = Dictionary(oldPads.compactMap { pad in pad.string("id").map { ($0.lowercased(), pad.string("name") ?? $0) } }, uniquingKeysWith: { first, _ in first })
            var stranded = [String: [String]]()
            for (id, track) in try board().dictionaryMap("tracks") {
                for end in ["from", "to"] {
                    let pieces = (track.dictionary(end)?.string("pad") ?? "").lowercased().split(separator: "/").map(String.init)
                    guard pieces.count == 2, packageIDs.contains(pieces[0]), padMapping[pieces[1]] == nil else { continue }
                    stranded[pieces[1], default: []].append(id)
                }
            }
            if !stranded.isEmpty, copper == "refuse" {
                let refdes = component.string("refdes") ?? componentID
                let names = stranded.keys.map { padNames[$0] ?? $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                let count = Set(stranded.values.flatMap { $0 }).count
                throw HorizontalDispatchError(
                    code: .invalidParams,
                    message: "\(count) track\(count == 1 ? "" : "s") end on pads of \(refdes) the new part has nothing for: \(names.joined(separator: ", ")). "
                        + "Map them in pad_map, or pass copper \"drop\" to remove those tracks with the remap; nothing was changed.",
                    details: ["pads": names, "tracks": Set(stranded.values.flatMap { $0 }).sorted()])
            }
            dropped = Set(stranded.values.flatMap { $0 }).sorted()
            try updateBoard { board in
                var tracks = board.dictionaryMap("tracks")
                for id in dropped { tracks.removeValue(forKey: id) }
                for (id, var track) in tracks {
                    for end in ["from", "to"] {
                        guard var endpoint = track.dictionary(end), let path = endpoint.string("pad") else { continue }
                        let pieces = path.lowercased().split(separator: "/").map(String.init)
                        guard pieces.count == 2, packageIDs.contains(pieces[0]), let pad = padMapping[pieces[1]] else { continue }
                        endpoint["pad"] = "\(pieces[0])/\(pad)"
                        track[end] = endpoint
                    }
                    tracks[id] = track
                }
                board["tracks"] = tracks
            }
            if !dropped.isEmpty { try collectJunctions() }
            // Vias under the old footprint stay where they were, and the new
            // one may not want them: thermal vias under an exposed pad that is
            // gone. They are named, for the caller to decide on.
            if let loaded = project.board {
                let area = packageIDs.flatMap { HorizontalDispatchMethods.packageArea($0, board: loaded) }
                for via in loaded.vias where area.contains(where: { HorizontalBoardOutlines.contains(via.position, in: $0) }) {
                    underFootprint.append(["via": via.id, "net": via.netID.flatMap { nets()[$0.lowercased()]?.string("name") } ?? via.netID as Any,
                                           "x_mm": HorizontalDispatchJSON.mm(via.position.x), "y_mm": HorizontalDispatchJSON.mm(via.position.y)])
                }
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
        if samePackage > 0 { change["pads_kept"] = samePackage }
        if byName > 0 { change["pads_mapped_by_name"] = byName }
        let byPinName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        if !droppedNoConnects.isEmpty { change["no_connects_dropped"] = droppedNoConnects.sorted(by: byPinName) }
        if !droppedAlternates.isEmpty { change["alternates_dropped"] = droppedAlternates.sorted(by: byPinName) }
        if !droppedInstances.isEmpty {
            change["symbols_removed"] = droppedInstances.sorted()
            change["pins_to_wire"] = foldedPins.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if let wiring = try clearDebris(since: debrisBefore) { change["wiring_removed"] = wiring }
        }
        if !dropped.isEmpty { change["tracks_dropped"] = dropped }
        if !underFootprint.isEmpty {
            change["vias_under_old_footprint"] = underFootprint
            change["note"] = "\(underFootprint.count) via\(underFootprint.count == 1 ? " sits" : "s sit") where the old footprint was; remove_via any the new one doesn't want."
        }
        touchedPins.formUnion(connections.keys.map { (componentID, $0.lowercased()) }.map { "\($0.0)|\($0.1)" })
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

    /// What each sheet drawing a component's symbols — one gate's, when given
    /// — holds that connects nothing, before they come off, so the wiring
    /// that served only them can be told from what was debris already. Empty
    /// when the caller keeps the wiring.
    private func debris(onSheetsDrawing componentID: String, gate gateID: String?, keep: Bool) throws -> [String: HorizontalSchematicDebris] {
        guard !keep, files["schematic"] != nil else { return [:] }
        var found = [String: HorizontalSchematicDebris]()
        for sheet in try sheetsInOrder() where sheet.json.dictionaryMap("symbols").values.contains(where: {
            $0.string("component")?.lowercased() == componentID && (gateID == nil || $0.string("gate")?.lowercased() == gateID)
        }) {
            found[sheet.id] = HorizontalSchematicDebris(sheet: sheet.json, block: block, symbolHasPin: pool.symbolHasPin)
        }
        return found
    }

    /// The wiring an edit left serving nothing that served something before:
    /// islands that now reach no pin, with their labels and power symbols, and
    /// dead ends that ran to a pin. Removing a part leaves both, and they are
    /// taken with it, junctions and all; what was debris before stays, for
    /// prune_sheet to decide on. Nil when there was none.
    private func clearDebris(since before: [String: HorizontalSchematicDebris]) throws -> JSONDictionary? {
        var counts = ["net_lines": 0, "net_labels": 0, "power_symbols": 0, "junctions": 0]
        for (sheetID, earlier) in before {
            guard let sheet = try sheetsInOrder().first(where: { $0.id == sheetID })?.json else { continue }
            let now = HorizontalSchematicDebris(sheet: sheet, block: block, symbolHasPin: pool.symbolHasPin)
            let lines = Set(now.unanchored.flatMap(\.lines) + now.stubs.flatMap(\.lines))
                .subtracting(earlier.unanchored.flatMap(\.lines) + earlier.stubs.flatMap(\.lines))
            let labels = Set(now.unanchored.flatMap(\.labels)).subtracting(earlier.unanchored.flatMap(\.labels))
            let power = Set(now.unanchored.flatMap(\.powerSymbols)).subtracting(earlier.unanchored.flatMap(\.powerSymbols))
            guard !(lines.isEmpty && labels.isEmpty && power.isEmpty) else { continue }
            var candidates = Set(now.unanchored.filter { !Set($0.lines).isDisjoint(with: lines) || !Set($0.labels).isDisjoint(with: labels)
                || !Set($0.powerSymbols).isDisjoint(with: power) }.flatMap(\.junctions).map { $0.lowercased() })
            candidates.formUnion(now.stubs.filter { !Set($0.lines).isDisjoint(with: lines) }.flatMap(\.junctions).map { $0.lowercased() })
            let netLines = sheet.dictionaryMap("net_lines")
            for line in lines { candidates.formUnion(netLines[line].map(Self.lineJunctions) ?? []) }
            for (key, doomed) in [("net_labels", labels), ("power_symbols", power)] {
                for mark in doomed { if let junction = sheet.dictionaryMap(key)[mark]?.string("junction") { candidates.insert(junction.lowercased()) } }
            }
            try updateSheet(sheetID) { sheet in
                for (key, doomed) in [("net_lines", lines), ("net_labels", labels), ("power_symbols", power)] where !doomed.isEmpty {
                    var map = sheet.dictionaryMap(key)
                    for id in doomed { map.removeValue(forKey: id) }
                    sheet[key] = map
                }
            }
            counts["net_lines", default: 0] += lines.count
            counts["net_labels", default: 0] += labels.count
            counts["power_symbols", default: 0] += power.count
            counts["junctions", default: 0] += try collectSheetJunctions(sheetID, candidates: candidates).count
        }
        let removed = counts.filter { $0.value > 0 }
        return removed.isEmpty ? nil : removed
    }

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

    /// An id that names a text edits it. One that names none makes the text
    /// under that id, as the other ops that make things do, which is what lets
    /// a batch name a text ("id": "t1") and edit or remove it later; making one
    /// needs its words and its place, so a mistyped id on a move still fails.
    private func placeText(_ params: JSONDictionary) throws -> JSONDictionary {
        let reference = params.string("id")
        let existing = try reference.flatMap { reference in
            try sheetTexts().first(where: { $0.id.caseInsensitiveCompare(reference) == .orderedSame })
        }
        if let reference, existing == nil {
            guard UUID(uuidString: reference) != nil, params.string("text") != nil, params.double("x_mm") != nil, params.double("y_mm") != nil else {
                throw HorizontalDispatchError.notFound(
                    "No text \(reference) on any sheet. list_texts returns the ids; to make a text under a new id, "
                        + "give a UUID or a name with text, x_mm and y_mm."
                )
            }
        }
        // A text a smash gave a symbol is the sheet's, to place as any other;
        // it stays the symbol's, and goes on drawing its refdes or value.
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
        // Horizon writes "layer": 0 on every sheet text, and reads a missing
        // one as 0; a text this op touches gets it, so Horizon's next save
        // has nothing to add.
        if item["layer"] == nil { item["layer"] = 0 }
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
        if existing == nil, params.double("x_mm") == nil || params.double("y_mm") == nil {
            throw HorizontalDispatchError.invalidParams("place_text needs \"x_mm\" and \"y_mm\" for a text that is not on a sheet yet.")
        }
        if let shift = Self.textShift(placement, params) { placement["shift"] = shift }
        if let degrees = params.double("angle_deg") { placement["angle"] = Self.horizonAngle(degrees) }
        if let mirror = params.bool("mirror") { placement["mirror"] = mirror }
        item["placement"] = placement

        let id = existing?.id ?? reference?.lowercased() ?? UUID().uuidString.lowercased()
        try updateSheet(targetSheet) { sheet in
            var texts = sheet["texts"] as? JSONDictionary ?? [:]
            texts[id] = item
            sheet["texts"] = texts
        }
        let (x, y) = Self.shift(placement)
        var change: JSONDictionary = ["text_id": id, "sheet": targetSheet, "text": item.string("text") as Any, "created": existing == nil,
                                      "x_mm": x / 1_000_000, "y_mm": y / 1_000_000]
        // Where it runs, and what it runs into: the text starts at x and goes
        // right, whatever its origin, so a note is easy to lay over a part.
        if let extent = Self.drawnText(item, id: id).map({ HorizontalRect(points: $0.renderBoundsPoints) }) {
            change["extent_mm"] = Self.rectJSON(extent)
            let overlaps = try overlaps(extent, onSheet: targetSheet, exceptText: id)
            if !overlaps.isEmpty { change["overlaps"] = overlaps }
        }
        return change
    }

    /// A sheet text as the canvas draws it, from its JSON.
    private static func drawnText(_ item: JSONDictionary, id: String) -> HorizontalText? {
        guard let placement = HorizontalPlacementTransform(json: item.dictionary("placement")), let text = item.string("text"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let drawn = HorizontalPlacementTransform.identity.accumulatedText(with: placement)
        return HorizontalText(id: id, text: text, position: drawn.shift, size: item.double("size") ?? 1_000_000, layer: item.int("layer"),
                              angle: drawn.angle, mirrored: drawn.mirrored, width: item.double("width") ?? 0,
                              origin: item.horizonTextOrigin(), font: item.horizonTextFont(),
                              allowUpsideDown: item.bool("allow_upside_down") ?? false)
    }

    private static func rectJSON(_ rect: HorizontalRect) -> JSONDictionary {
        ["min_x": HorizontalDispatchJSON.mm(rect.minX), "min_y": HorizontalDispatchJSON.mm(rect.minY),
         "max_x": HorizontalDispatchJSON.mm(rect.maxX), "max_y": HorizontalDispatchJSON.mm(rect.maxY)]
    }

    /// What a box on a sheet covers: symbols by the box their pin ends span
    /// (a part's body lies between its pins) widened by half a grid step,
    /// net labels by their name's run from their junction, power symbols
    /// near their junction, and other texts by what they draw.
    private func overlaps(_ box: HorizontalRect, onSheet sheetID: String, exceptText: String) throws -> [JSONDictionary] {
        guard let sheet = try sheetsInOrder().first(where: { $0.id == sheetID })?.json else { return [] }
        var found = [JSONDictionary]()
        let half = 1_270_000.0
        for (id, symbol) in sheet.dictionaryMap("symbols") {
            let reach = HorizontalSchematicTextProximity.reach(of: symbol, pool: pool)
            guard !reach.isEmpty, Self.around(reach, by: half).intersects(box) else { continue }
            let component = symbol.string("component")?.lowercased()
            found.append(["kind": "symbol", "symbol_instance": id,
                          "refdes": component.flatMap { components()[$0]?.string("refdes") } as Any])
        }
        let junctions = sheet.dictionaryMap("junctions").reduce(into: [String: HorizontalPoint]()) { result, entry in
            if let point = entry.value["position"] as? [Any], point.count == 2 {
                result[entry.key.lowercased()] = HorizontalPoint(x: JSONHelper.doubleValue(point[0]), y: JSONHelper.doubleValue(point[1]))
            }
        }
        for (id, label) in sheet.dictionaryMap("net_labels") {
            guard let at = label.string("junction").flatMap({ junctions[$0.lowercased()] }) else { continue }
            let net = label.string("last_net")?.lowercased()
            let name = net.flatMap { nets()[$0]?.string("name") } ?? ""
            let size = label.double("size") ?? 1_500_000
            let run = Double(max(name.count, 1)) * size * 0.95 + size
            let direction: (x: Double, y: Double) = ["left": (-1, 0), "up": (0, 1), "down": (0, -1)][label.string("orientation") ?? ""] ?? (1, 0)
            let far = HorizontalPoint(x: at.x + direction.x * run, y: at.y + direction.y * run)
            guard Self.around([at, far], by: size * 0.6).intersects(box) else { continue }
            found.append(["kind": "net_label", "net_label": id, "net": name])
        }
        for (id, symbol) in sheet.dictionaryMap("power_symbols") {
            guard let at = symbol.string("junction").flatMap({ junctions[$0.lowercased()] }),
                  Self.around([at], by: 2_540_000).intersects(box) else { continue }
            found.append(["kind": "power_symbol", "power_symbol": id,
                          "net": symbol.string("net").flatMap { nets()[$0.lowercased()]?.string("name") } as Any])
        }
        for (id, text) in sheet.dictionaryMap("texts") where id.lowercased() != exceptText.lowercased() {
            guard let drawn = Self.drawnText(text, id: id), HorizontalRect(points: drawn.renderBoundsPoints).intersects(box) else { continue }
            found.append(["kind": "text", "text_id": id, "text": drawn.text])
        }
        return found.sorted { ($0.string("kind") ?? "", $0.string("refdes") ?? $0.string("net") ?? $0.string("text") ?? "")
            < ($1.string("kind") ?? "", $1.string("refdes") ?? $1.string("net") ?? $1.string("text") ?? "") }
    }

    /// The box points span, widened on every side. A rect of points in a
    /// line has no area, and HorizontalRect leaves an empty rect as it is.
    private static func around(_ points: [HorizontalPoint], by amount: Double) -> HorizontalRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return HorizontalRect(points: [HorizontalPoint(x: (xs.min() ?? 0) - amount, y: (ys.min() ?? 0) - amount),
                                       HorizontalPoint(x: (xs.max() ?? 0) + amount, y: (ys.max() ?? 0) + amount)])
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
                "\(found.id) is a symbol's own text, from a smash; unsmash removes it, and removing the symbol does too."
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

    /// Where a wire end sits on a sheet: its junction's position, or the end
    /// of the pin it names as the symbol draws it there. Nil for anything else.
    private func wireEndPosition(_ end: JSONDictionary?, sheet: JSONDictionary) -> HorizontalPoint? {
        guard let end else { return nil }
        if let junction = end.string("junc")?.lowercased() {
            guard let position = sheet.dictionaryMap("junctions").first(where: { $0.key.lowercased() == junction })?.value["position"] as? [Any],
                  position.count == 2 else { return nil }
            return HorizontalPoint(x: JSONHelper.doubleValue(position[0]), y: JSONHelper.doubleValue(position[1]))
        }
        guard let path = end.string("pin")?.lowercased() else { return nil }
        let pieces = path.split(separator: "/").map(String.init)
        guard pieces.count == 2, let instance = sheet.dictionaryMap("symbols").first(where: { $0.key.lowercased() == pieces[0] })?.value,
              let symbol = instance.string("symbol"), let geometry = pool.symbolPin(symbol, pin: pieces[1]) else { return nil }
        return (HorizontalPlacementTransform(json: instance.dictionary("placement")) ?? .identity).schematicGeometry.applying(to: geometry.position)
    }

    /// A mark for `net` at `point` with no junction there yet: on a wire of the
    /// net, the wire is split there, as the app's label tool splits it, and the
    /// junction between the halves is returned; a wire of another net, or a
    /// pin's end, is refused, since the mark would join it or sit on it
    /// joined to nothing. Nil when the point is clear.
    private func splitWire(at point: [Int], sheetID: String, net: String) throws -> String? {
        guard let sheet = try sheetsInOrder().first(where: { $0.id == sheetID })?.json else { return nil }
        let at = HorizontalPoint(x: Double(point[0]), y: Double(point[1]))
        func same(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Bool { abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 }
        let where_ = "(\(HorizontalDispatchJSON.mm(at.x)), \(HorizontalDispatchJSON.mm(at.y)))"
        for (id, instance) in sheet.dictionaryMap("symbols") {
            guard let symbol = instance.string("symbol") else { continue }
            let transform = (HorizontalPlacementTransform(json: instance.dictionary("placement")) ?? .identity).schematicGeometry
            for pin in pool.symbolPins(symbol).values where same(transform.applying(to: pin.position), at) {
                let component = instance.string("component").flatMap { components()[$0.lowercased()]?.string("refdes") } ?? id
                throw HorizontalDispatchError.invalidParams(
                    "\(where_) is the end of a pin of \(component); a mark there joins nothing. terminate_pin draws a stub from the pin to a label or power symbol.")
            }
        }
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet, block: block)
        for (lineID, line) in sheet.dictionaryMap("net_lines") {
            guard let from = wireEndPosition(line.dictionary("from"), sheet: sheet), let to = wireEndPosition(line.dictionary("to"), sheet: sheet),
                  !same(from, at), !same(to, at) else { continue }
            let vector = to - from, offset = at - from
            guard abs(vector.x * offset.y - vector.y * offset.x) < 1,
                  at.x >= min(from.x, to.x), at.x <= max(from.x, to.x), at.y >= min(from.y, to.y), at.y <= max(from.y, to.y) else { continue }
            let wireNet = line.dictionary("from").flatMap { connectivity.net(at: $0) }?.lowercased() ?? line.string("net")?.lowercased()
            guard wireNet == nil || wireNet == net.lowercased() else {
                let name = wireNet.flatMap { nets()[$0]?.string("name") }.flatMap { $0.isEmpty ? nil : $0 } ?? wireNet!
                throw HorizontalDispatchError.invalidParams("\(where_) is on wire \(lineID) of \(name); a mark for another net there would join them.")
            }
            let junction = UUID().uuidString.lowercased()
            let middle: JSONDictionary = ["junc": junction, "pin": NSNull(), "port": NSNull(), "bus_ripper": NSNull()]
            try updateSheet(sheetID) { sheet in
                var junctions = sheet.dictionaryMap("junctions")
                junctions[junction] = ["position": point, "net": net]
                sheet["junctions"] = junctions
                var lines = sheet.dictionaryMap("net_lines")
                lines.removeValue(forKey: lineID)
                var first = line, second = line
                first["to"] = middle
                second["from"] = middle
                lines[lineID] = first
                lines[UUID().uuidString.lowercased()] = second
                sheet["net_lines"] = lines
            }
            splitWires.append(lineID)
            return junction
        }
        return nil
    }

    /// Wires a mark split in this batch, for the change that placed it.
    private var splitWires = [String]()

    /// A junction on a schematic sheet, at a point, carrying a net. Net labels
    /// and power symbols both sit on one; a point that already has one joins it,
    /// and one on a wire of the net splits the wire there.
    private func ensureSheetJunction(_ sheetID: String, x: Double, y: Double, net: String?) throws -> String {
        let point = [Self.nanometres(x), Self.nanometres(y)]
        let sheets = try sheetsInOrder()
        let sheetJSON = sheets.first { $0.id == sheetID }?.json ?? [:]
        let existing = sheetJSON.dictionaryMap("junctions").first { $0.value["position"] as? [Int] == point }
        if existing == nil, let net, let junction = try splitWire(at: point, sheetID: sheetID, net: net) {
            return junction
        }
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
        if !splitWires.isEmpty { change["split_net_line"] = splitWires.removeLast() }
        if madePower { change["note"] = "The net is now a power net, which is what a power symbol on it means." }
        if let style { change["style"] = style }
        return change
    }

    /// A net or bus label already on a sheet, changed in place as place_text
    /// changes a text: its orientation, size and off-sheet refs, and with
    /// x_mm or y_mm its place, onto the junction or wire there. It keeps its
    /// id and, a net label, its net. Nil when `id` names no label of the kind.
    private func editSheetLabel(_ params: JSONDictionary, key: String, id reference: String) throws -> JSONDictionary? {
        guard let holder = try sheetsInOrder().first(where: { $0.json.dictionaryMap(key).keys.contains { $0.lowercased() == reference } }),
              let id = holder.json.dictionaryMap(key).keys.first(where: { $0.lowercased() == reference }),
              var item = holder.json.dictionaryMap(key)[id] else { return nil }
        let isNet = key == "net_labels"
        if params["sheet"] != nil, try sheetID(params) != holder.id {
            throw HorizontalDispatchError.invalidParams("\(id) is on another sheet; a label moves on its own sheet. remove it, and place one there.")
        }
        let junctions = holder.json.dictionaryMap("junctions")
        let oldJunction = item.string("junction")
        let connectivity = HorizontalSchematicNetConnectivity(sheet: holder.json, block: block)
        let net = isNet ? (oldJunction.flatMap { connectivity.net(at: ["junc": $0]) } ?? item.string("last_net"))?.lowercased() : nil
        if isNet, params["net"] != nil, try netID(params).lowercased() != net {
            throw HorizontalDispatchError.invalidParams("Net label \(id) is on \(net.flatMap { nets()[$0]?.string("name") } ?? "no net"); a label keeps its junction's net. remove_net_label it and place one for the other net.")
        }
        if !isNet, params["bus"] != nil, try busID(params).lowercased() != item.string("bus")?.lowercased() {
            throw HorizontalDispatchError.invalidParams("Bus label \(id) names another bus; remove it and place one for this bus.")
        }
        if params["orientation"] != nil {
            item["orientation"] = try markOption(params, key: "orientation", allowed: Self.markOrientations, default: "right")
        }
        if let size = params.double("size_mm") {
            guard size > 0 else { throw HorizontalDispatchError.invalidParams("size_mm must be more than zero.") }
            item["size"] = Self.nanometres(size)
        }
        if isNet, let refs = params.bool("offsheet_refs") { item["offsheet_refs"] = refs }
        if isNet, let showsPort = params.bool("show_port") { item["show_port"] = showsPort }
        var moved: String?
        if params["x_mm"] != nil || params["y_mm"] != nil {
            let current = oldJunction.flatMap { key in junctions.first { $0.key.lowercased() == key.lowercased() }?.value["position"] as? [Any] } ?? [0, 0]
            let x = params.double("x_mm") ?? JSONHelper.doubleValue(current.first ?? 0) / 1_000_000
            let y = params.double("y_mm") ?? JSONHelper.doubleValue(current.count > 1 ? current[1] : 0) / 1_000_000
            let junction = try ensureSheetJunction(holder.id, x: x, y: y, net: net)
            if junction.lowercased() != oldJunction?.lowercased() {
                item["junction"] = junction
                moved = junction
            }
        }
        try updateSheet(holder.id) { sheet in
            var map = sheet.dictionaryMap(key)
            map[id] = item
            sheet[key] = map
        }
        var change: JSONDictionary = [isNet ? "net_label" : "bus_label": id, "sheet": holder.id, "created": false,
                                      "junction": item.string("junction") as Any, "orientation": item.string("orientation") as Any]
        if isNet { change["net"] = net as Any }
        if let moved, let oldJunction {
            change["junctions_removed"] = try collectSheetJunctions(holder.id, candidates: [oldJunction.lowercased()])
            change["moved_to"] = moved
        }
        if !splitWires.isEmpty { change["split_net_line"] = splitWires.removeLast() }
        return change
    }

    private func placeNetLabel(_ params: JSONDictionary) throws -> JSONDictionary {
        if let reference = params.string("id")?.lowercased(), let edited = try editSheetLabel(params, key: "net_labels", id: reference) {
            return edited
        }
        let net = try netID(params)
        let sheetID = try sheetID(params)
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_net_label needs \"x_mm\" and \"y_mm\" for a new label.")
        }
        let orientation = try markOption(params, key: "orientation", allowed: Self.markOrientations, default: "right")
        let sizeMM = params.double("size_mm") ?? 1.5
        guard sizeMM > 0 else { throw HorizontalDispatchError.invalidParams("size_mm must be more than zero.") }
        let junction = try ensureSheetJunction(sheetID, x: x, y: y, net: net)
        let id = try editObjectID(params)
        try updateSheet(sheetID) { sheet in
            var labels = sheet["net_labels"] as? JSONDictionary ?? [:]
            var label: JSONDictionary = ["junction": junction, "last_net": net, "size": Self.nanometres(sizeMM),
                                         "orientation": orientation, "offsheet_refs": params.bool("offsheet_refs") ?? true]
            if let showsPort = params.bool("show_port") { label["show_port"] = showsPort }
            labels[id] = label
            sheet["net_labels"] = labels
        }
        var change: JSONDictionary = ["net_label": id, "net": net, "sheet": sheetID, "junction": junction,
                                      "orientation": orientation, "size_mm": sizeMM]
        if !splitWires.isEmpty { change["split_net_line"] = splitWires.removeLast() }
        return change
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
        knownBlocks.filter { $0.uuid.lowercased() != blockID.lowercased() }
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
        let candidates = HorizontalProjectBlock.matching(reference, in: usableBlocks())
        guard candidates.count == 1, let used = candidates.first else {
            if candidates.isEmpty {
                // Naming the block being edited is the mistake worth catching.
                if knownBlocks.contains(where: { $0.uuid.caseInsensitiveCompare(reference) == .orderedSame }) {
                    throw HorizontalDispatchError.invalidParams("A block cannot use itself.")
                }
                throw HorizontalDispatchError.notFound(
                    "No block \(reference). Blocks this one can use: \(usableBlocks().map(\.displayName).joined(separator: ", "))."
                )
            }
            throw HorizontalDispatchError.ambiguous("More than one block is called \(reference); use its uuid.",
                                                    candidates: candidates.map(\.uuid))
        }
        // Horizon's `can_add_block_instance`, over every block rather than
        // only the paths instantiated so far: a block that uses this one,
        // however deep, cannot be used inside it.
        if try blocksUsed(by: used.uuid).contains(blockID.lowercased()) {
            throw HorizontalDispatchError.invalidParams(
                "\(used.displayName) already uses \(knownBlocks.first { $0.uuid.lowercased() == blockID.lowercased() }?.displayName ?? "this block"), so it can't be used inside it."
            )
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        var instances = blockInstances()
        guard instances[id] == nil else {
            throw HorizontalDispatchError.invalidParams("A block instance \(id) already exists.")
        }
        // Horizon names a new instance I? and leaves the rest to the user.
        let refdes = params.string("refdes") ?? "I?"
        instances[id] = ["block": used.uuid, "refdes": refdes, "connections": [String: Any]()]
        block["block_instances"] = instances
        let mappings = try createInstanceMappings()
        var change: JSONDictionary = ["block_instance": id, "block": used.uuid, "block_name": used.displayName, "refdes": refdes,
                                      "note": "Its ports reach this block through connect_block_port, and place_block_symbol draws it."]
        if !mappings.isEmpty { change["instance_mappings"] = mappings }
        return change
    }

    private func removeBlockInstance(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        var instances = blockInstances()
        instances.removeValue(forKey: id)
        block["block_instances"] = instances
        let symbols = try removeBlockSymbols(instanceID: id, sheetFilter: nil)
        var change: JSONDictionary = ["block_instance": id, "symbols": symbols]
        let mappings = try removeInstanceMappings { $0.contains(id) }
        if mappings > 0 { change["instance_mappings_removed"] = mappings }
        return change
    }

    /// A block's ports are the nets it declares as ports; a using block wires
    /// its own nets onto them.
    private func blockPortID(_ reference: String, of usedBlockID: String) throws -> String {
        guard let json = try? blockFile(usedBlockID) else {
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
        var connections = instance["connections"] as? JSONDictionary ?? [:]
        // Horizon's NC port: a connection to no net, which nothing can wire.
        if params.bool("nc") == true {
            if let net = (connections[port] as? JSONDictionary)?.string("net") {
                throw HorizontalDispatchError.invalidParams(
                    "That port is connected to net \(nets()[net]?.string("name") ?? net); disconnect_block_port it first."
                )
            }
            connections[port] = ["net": NSNull()]
            instance["connections"] = connections
            instances[id] = instance
            block["block_instances"] = instances
            return ["block_instance": id, "port": port, "nc": true]
        }
        let net: String
        if let existing = try existingNetID(params) {
            net = existing
        } else if params.bool("create_net") ?? false, let name = params.string("net") {
            net = try ensureNet(["name": name]).0
        } else {
            throw HorizontalDispatchError.notFound("No net matches \(params["net"] ?? "nothing"); pass create_net to make it.")
        }
        connections[port] = ["net": net]
        instance["connections"] = connections
        instances[id] = instance
        block["block_instances"] = instances
        return ["block_instance": id, "port": port, "net": net]
    }

    private func disconnectBlockPort(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        var instances = blockInstances()
        guard var instance = instances[id] as? JSONDictionary, let usedBlock = instance.string("block") else {
            throw HorizontalDispatchError.notFound("Block instance \(id) names no block.")
        }
        guard let portReference = params.string("port") else {
            throw HorizontalDispatchError.invalidParams("disconnect_block_port needs \"port\".")
        }
        let port = try blockPortID(portReference, of: usedBlock)
        var connections = instance["connections"] as? JSONDictionary ?? [:]
        let removed = connections.removeValue(forKey: port) != nil
        instance["connections"] = connections
        instances[id] = instance
        block["block_instances"] = instances
        return ["block_instance": id, "port": port, "disconnected": removed]
    }

    private func placeBlockSymbol(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        guard let instance = blockInstances()[id] as? JSONDictionary, let usedBlock = instance.string("block") else {
            throw HorizontalDispatchError.notFound("Block instance \(id) names no block.")
        }
        // A block draws itself with the symbol it defines; without one there is
        // nothing to put on the sheet.
        guard let used = knownBlocks.first(where: { $0.uuid.lowercased() == usedBlock.lowercased() }),
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

    // MARK: - Blocks

    /// The project's blocks as this batch has left them: a block added by
    /// an earlier op can be used by a later one.
    private lazy var knownBlocks: [HorizontalProjectBlock] = project.blocks

    private func knownBlock(_ blockID: String) -> HorizontalProjectBlock? {
        knownBlocks.first { $0.uuid.lowercased() == blockID.lowercased() }
    }

    /// The block `params[key]` names, among the blocks this batch knows.
    private func blockReference(_ params: JSONDictionary, key: String = "block") throws -> HorizontalProjectBlock {
        guard let reference = params.string(key), !reference.isEmpty else {
            throw HorizontalDispatchError.invalidParams("\(key) is required: a block's uuid or name.")
        }
        let matches = HorizontalProjectBlock.matching(reference, in: knownBlocks)
        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty {
                throw HorizontalDispatchError.notFound("No block \(reference). Blocks: \(knownBlocks.map(\.displayName).joined(separator: ", ")).")
            }
            throw HorizontalDispatchError.ambiguous("More than one block is called \(reference); use its uuid.",
                                                    candidates: matches.map(\.uuid))
        }
        return match
    }

    /// A project file the editor reads beside the block it edits — another
    /// block's file, a symbol, `blocks.json` — under the key that names it.
    /// The edited block's own files keep their keys ("block", "schematic"),
    /// so no file is ever held twice.
    private func projectFile(_ relativePath: String) throws -> JSONDictionary? {
        let key = "file:" + relativePath
        if files[key] == nil {
            try load(key, url: project.baseURL.appendingPathComponent(relativePath))
        }
        return files[key]
    }

    private func setProjectFile(_ relativePath: String, _ json: JSONDictionary) {
        let key = "file:" + relativePath
        files[key] = json
        fileURLs[key] = project.baseURL.appendingPathComponent(relativePath)
        dirty.insert(key)
        removedFiles.removeAll { $0 == relativePath }
    }

    private func removeProjectFile(_ relativePath: String) {
        let key = "file:" + relativePath
        files.removeValue(forKey: key)
        fileURLs.removeValue(forKey: key)
        dirty.remove(key)
        if !removedFiles.contains(relativePath) { removedFiles.append(relativePath) }
    }

    /// A block's own file: the one edited, or another read beside it.
    private func blockFile(_ id: String) throws -> JSONDictionary {
        if id.lowercased() == blockID.lowercased() {
            return block
        }
        guard let filename = knownBlock(id)?.blockFilename, !filename.isEmpty, let json = try projectFile(filename) else {
            throw HorizontalDispatchError.notFound("Could not read block \(id)'s file.")
        }
        return json
    }

    private func updateBlockFile(_ id: String, _ body: (inout JSONDictionary) throws -> Void) throws {
        if id.lowercased() == blockID.lowercased() {
            var json = block
            try body(&json)
            block = json
            return
        }
        guard let filename = knownBlock(id)?.blockFilename, !filename.isEmpty else {
            throw HorizontalDispatchError.notFound("Block \(id) has no file.")
        }
        var json = try blockFile(id)
        try body(&json)
        setProjectFile(filename, json)
    }

    private func updateSchematicFile(of id: String, _ body: (inout JSONDictionary) throws -> Void) throws {
        if id.lowercased() == blockID.lowercased() {
            guard var json = files["schematic"] else { return }
            try body(&json)
            files["schematic"] = json
            dirty.insert("schematic")
            return
        }
        guard let filename = knownBlock(id)?.schematicFilename, !filename.isEmpty, var json = try projectFile(filename) else {
            return
        }
        try body(&json)
        setProjectFile(filename, json)
    }

    /// The blocks `id` uses, however deep: through its instances, their
    /// blocks' instances, and so on.
    private func blocksUsed(by id: String) throws -> Set<String> {
        var used = Set<String>()
        var pending = [id.lowercased()]
        while let next = pending.popLast() {
            let instances = (try? blockFile(next))?.dictionaryMap("block_instances") ?? [:]
            for instance in instances.values {
                guard let child = instance.string("block")?.lowercased(), used.insert(child).inserted else { continue }
                pending.append(child)
            }
        }
        return used
    }

    /// Every instance path from the top block down, Horizon's
    /// `get_instantiated_blocks`: each path, `/`-joined instance uuids, with
    /// the block it reaches.
    private func instancePaths() throws -> [(path: String, block: String)] {
        guard let top = knownBlocks.first(where: \.isTop) else { return [] }
        var result = [(path: String, block: String)]()
        func visit(_ id: String, prefix: [String], depth: Int) throws {
            // Horizon's `max_instance_path_len`.
            guard depth < 10 else { return }
            for (instanceID, instance) in try blockFile(id).dictionaryMap("block_instances").sorted(by: { $0.key < $1.key }) {
                guard let child = instance.string("block")?.lowercased() else { continue }
                let path = prefix + [instanceID.lowercased()]
                result.append((path.joined(separator: "/"), child))
                try visit(child, prefix: path, depth: depth + 1)
            }
        }
        try visit(top.uuid, prefix: [], depth: 0)
        return result
    }

    /// Horizon's `create_instance_mappings`: the top block gets an entry
    /// for every instance path it lacks, which is where each instance's own
    /// refdes and no-populate go. Horizon's board reads one for every path,
    /// so an instance made without it would not open there. Returns the
    /// paths added.
    private func createInstanceMappings() throws -> [String] {
        guard let top = knownBlocks.first(where: \.isTop) else { return [] }
        var mappings = try blockFile(top.uuid)["block_instance_mappings"] as? JSONDictionary ?? [:]
        var added = [String]()
        for (path, child) in try instancePaths() where mappings[path] == nil {
            mappings[path] = ["block": child, "components": [String: Any]()]
            added.append(path)
        }
        guard !added.isEmpty else { return [] }
        try updateBlockFile(top.uuid) { $0["block_instance_mappings"] = mappings }
        return added
    }

    /// Takes the top block's mappings for the instance paths `isDoomed`
    /// picks, by their instance uuids. Returns how many went.
    private func removeInstanceMappings(where isDoomed: ([String]) -> Bool) throws -> Int {
        guard let top = knownBlocks.first(where: \.isTop) else { return 0 }
        guard let mappings = try blockFile(top.uuid)["block_instance_mappings"] as? JSONDictionary else { return 0 }
        let kept = mappings.filter { !isDoomed($0.key.lowercased().split(separator: "/").map(String.init)) }
        guard kept.count != mappings.count else { return 0 }
        try updateBlockFile(top.uuid) { $0["block_instance_mappings"] = kept }
        return mappings.count - kept.count
    }

    /// An instance path from the top block, `I1/I2` by refdes or by uuid,
    /// as the instance uuids it names. It has to end at an instance of the
    /// block being edited, whose components it gives refdes to.
    private func instancePath(_ reference: String) throws -> [String] {
        guard let top = knownBlocks.first(where: \.isTop) else {
            throw HorizontalDispatchError.failed("The project has no top block.")
        }
        var path = [String]()
        var current = top.uuid
        for step in reference.split(separator: "/").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
            let instances = try blockFile(current).dictionaryMap("block_instances")
            var matches = instances.filter { $0.key.caseInsensitiveCompare(step) == .orderedSame }
            if matches.isEmpty { matches = instances.filter { $0.value.string("refdes") == step } }
            guard matches.count == 1, let match = matches.first, let child = match.value.string("block") else {
                throw matches.isEmpty
                    ? HorizontalDispatchError.notFound("No instance \(step) in \(knownBlock(current)?.displayName ?? current).")
                    : HorizontalDispatchError.ambiguous("More than one instance is called \(step); use its uuid.", candidates: matches.keys.sorted())
            }
            path.append(match.key.lowercased())
            current = child
        }
        guard !path.isEmpty, current.lowercased() == blockID.lowercased() else {
            throw HorizontalDispatchError.invalidParams(
                "\(reference) is not an instance of \(knownBlock(blockID)?.displayName ?? "this block"); name the block its component is in with block."
            )
        }
        return path
    }

    /// One instance's own refdes and no-populate for a component, Horizon's
    /// `block_instance_mappings` entry, which the top block keeps for every
    /// instance path. Returns the path, `/`-joined.
    private func updateInstanceMapping(component: String, _ params: JSONDictionary,
                                       _ body: (inout JSONDictionary) -> Void) throws -> String {
        guard !isTopBlock else {
            throw HorizontalDispatchError.invalidParams("instance names a use of a sub-block's component; the top block's components are used once.")
        }
        let path = try instancePath(params.string("instance") ?? "")
        let key = path.joined(separator: "/")
        guard let top = knownBlocks.first(where: \.isTop) else { return key }
        let ownRefdes = components()[component]?.string("refdes") ?? ""
        let ownNoPopulate = components()[component]?.bool("nopopulate") ?? false
        try updateBlockFile(top.uuid) { json in
            var mappings = json["block_instance_mappings"] as? JSONDictionary ?? [:]
            let mappingKey = mappings.keys.first { $0.lowercased() == key } ?? key
            var mapping = mappings[mappingKey] as? JSONDictionary ?? ["block": blockID]
            var entries = mapping["components"] as? JSONDictionary ?? [:]
            let entryKey = entries.keys.first { $0.lowercased() == component.lowercased() } ?? component
            var entry = entries[entryKey] as? JSONDictionary ?? ["refdes": ownRefdes, "nopopulate": ownNoPopulate]
            body(&entry)
            entries[entryKey] = entry
            mapping["components"] = entries
            mappings[mappingKey] = mapping
            json["block_instance_mappings"] = mappings
        }
        return key
    }

    // MARK: - Annotation

    /// Horizon's `Schematic::annotate`, over the whole hierarchy: the top
    /// block's sheets in page order, each followed by the sheets of the
    /// blocks drawn on it, by instance refdes — the order Horizon numbers
    /// pages in. Each instance's components are numbered under its mapping,
    /// and the counters run across the whole design.
    private func annotate(_ params: JSONDictionary) throws -> JSONDictionary {
        guard isTopBlock, let top = knownBlocks.first(where: \.isTop) else {
            throw HorizontalDispatchError.invalidParams("annotate numbers the whole design; run it on the top block.")
        }
        var options = files["schematic"]?["annotation"] as? JSONDictionary ?? [:]
        let defaults: JSONDictionary = ["mode": "sheet_100", "order": "right_down", "fill_gaps": true, "keep": true, "ignore_unknown": false]
        var optionsChanged = false
        for key in ["mode", "order", "fill_gaps", "keep", "ignore_unknown"] where params[key] != nil {
            options[key] = params[key]
            optionsChanged = true
        }
        let mode = options.string("mode") ?? defaults.string("mode")!
        let order = options.string("order") ?? defaults.string("order")!
        guard ["sequential", "sheet_100", "sheet_1000"].contains(mode) else {
            throw HorizontalDispatchError.invalidParams("mode must be sequential, sheet_100 or sheet_1000.")
        }
        guard ["right_down", "down_right"].contains(order) else {
            throw HorizontalDispatchError.invalidParams("order must be right_down or down_right.")
        }
        let fillGaps = options.bool("fill_gaps") ?? true
        let keep = options.bool("keep") ?? true
        let ignoreUnknown = options.bool("ignore_unknown") ?? false
        if optionsChanged, var schematic = files["schematic"] {
            schematic["annotation"] = defaults.merging(options) { _, given in given }
            files["schematic"] = schematic
            dirty.insert("schematic")
        }

        // What annotation reads and writes, held here and written once.
        var blockFiles = [String: JSONDictionary]()
        func blockJSON(_ id: String) throws -> JSONDictionary {
            if let cached = blockFiles[id] { return cached }
            let json = try blockFile(id)
            blockFiles[id] = json
            return json
        }
        var mappings = try blockFile(top.uuid)["block_instance_mappings"] as? JSONDictionary ?? [:]
        var refdesChanges = [String: [String: String]]()   // block → component → refdes (top level of each block)
        var finalRefdes = [String: String]()
        var original = [String: String]()   // block|path|component → refdes before

        func ownComponent(_ component: String, in block: String) throws -> JSONDictionary? {
            try blockJSON(block).dictionaryMap("components").first { $0.key.lowercased() == component }?.value
        }
        func refdes(_ component: String, in block: String, path: [String]) throws -> String {
            if path.isEmpty {
                if let changed = refdesChanges[block]?[component] { return changed }
                return try ownComponent(component, in: block)?.string("refdes") ?? ""
            }
            let key = path.joined(separator: "/")
            if let mapped = (mappings[key] as? JSONDictionary)?.dictionaryMap("components")
                .first(where: { $0.key.lowercased() == component })?.value.string("refdes") {
                return mapped
            }
            return try ownComponent(component, in: block)?.string("refdes") ?? ""
        }
        func setRefdes(_ component: String, in block: String, path: [String], to value: String) throws {
            let previous = try refdes(component, in: block, path: path)
            guard previous != value else { return }
            let key = "\(block)|\(path.joined(separator: "/"))|\(component)"
            if original[key] == nil { original[key] = previous }
            finalRefdes[key] = value
            if path.isEmpty {
                refdesChanges[block, default: [:]][component] = value
                return
            }
            let mappingKey = path.joined(separator: "/")
            var mapping = mappings[mappingKey] as? JSONDictionary ?? ["block": block]
            var entries = mapping["components"] as? JSONDictionary ?? [:]
            let ownNoPopulate = try ownComponent(component, in: block)?.bool("nopopulate") ?? false
            var entry = entries[component] as? JSONDictionary ?? ["nopopulate": ownNoPopulate]
            entry["refdes"] = value
            entries[component] = entry
            mapping["components"] = entries
            mappings[mappingKey] = mapping
        }
        func prefix(of component: JSONDictionary) -> String {
            if let entity = component.string("entity"), let prefix = pool.entity(entity)?.prefix, !prefix.isEmpty {
                return prefix
            }
            return String((component.string("refdes") ?? "").prefix { $0.isLetter })
        }

        var counters = [String: [Int]]()
        var sheetNumber = 0
        func visit(_ block: String, path: [String]) throws {
            guard path.count < HorizontalBlockFlattener.maximumDepth else { return }
            let json = try blockJSON(block)
            let components = json.dictionaryMap("components").reduce(into: [String: JSONDictionary]()) { $0[$1.key.lowercased()] = $1.value }
            if !keep {
                for id in components.keys.sorted() { try setRefdes(id, in: block, path: path, to: "?") }
            }
            for component in components.values { counters[prefix(of: component), default: []] = counters[prefix(of: component)] ?? [] }

            let schematic: JSONDictionary?
            if block.lowercased() == blockID.lowercased() {
                schematic = files["schematic"]
            } else {
                schematic = try knownBlock(block)?.schematicFilename.flatMap { try projectFile($0) }
            }
            let sheets = (schematic?.dictionaryMap("sheets") ?? [:]).sorted { ($0.value.int("index") ?? 0, $0.key) < ($1.value.int("index") ?? 0, $1.key) }
            for (_, sheet) in sheets {
                sheetNumber += 1
                var offset = 0, increment = 0
                if mode != "sequential" {
                    for key in counters.keys { counters[key] = [] }
                    increment = mode == "sheet_100" ? 100 : 1000
                    offset = increment * sheetNumber
                }
                var symbols = sheet.dictionaryMap("symbols").values.compactMap { symbol -> (component: String, x: Double, y: Double)? in
                    guard let component = symbol.string("component")?.lowercased(), components[component] != nil else { return nil }
                    let shift = HorizontalPlacementTransform(json: symbol.dictionary("placement"))?.shift ?? .zero
                    return (component, shift.x, shift.y)
                }
                // Horizon sorts by one axis, then stably by the other.
                if order == "right_down" {
                    symbols.sort { $0.x < $1.x }
                    symbols = symbols.enumerated().sorted { ($0.element.y, -$0.offset) > ($1.element.y, -$1.offset) }.map(\.element)
                } else {
                    symbols.sort { $0.y > $1.y }
                    symbols = symbols.enumerated().sorted { ($0.element.x, $0.offset) < ($1.element.x, $1.offset) }.map(\.element)
                }
                for symbol in symbols {
                    guard let component = components[symbol.component] else { continue }
                    let thePrefix = prefix(of: component)
                    let current = try refdes(symbol.component, in: block, path: path)
                    guard !current.contains("?") else { continue }
                    if let number = Int(current.dropFirst(thePrefix.count)), current.hasPrefix(thePrefix), number > 0 {
                        counters[thePrefix, default: []].append(number)
                        counters[thePrefix]?.sort()
                    } else if !ignoreUnknown {
                        try setRefdes(symbol.component, in: block, path: path, to: "?")
                    }
                }
                for symbol in symbols {
                    guard let component = components[symbol.component] else { continue }
                    let thePrefix = prefix(of: component)
                    var used = counters[thePrefix] ?? []
                    if try refdes(symbol.component, in: block, path: path).contains("?") {
                        var number = 1 + offset
                        if !used.isEmpty {
                            number = used.last! + 1
                            if fillGaps, used.count >= 2 {
                                for (value, next) in zip(used, used.dropFirst()) where value > offset && next != value + 1 {
                                    number = value + 1
                                    break
                                }
                            }
                        }
                        if increment > 0, number / increment != sheetNumber {
                            number = offset + 1
                        }
                        used.append(number)
                        try setRefdes(symbol.component, in: block, path: path, to: thePrefix + String(number))
                    }
                    counters[thePrefix] = used.sorted()
                }

                let instances = json.dictionaryMap("block_instances")
                let blockSymbols = sheet.dictionaryMap("block_symbols").values.compactMap { item -> (id: String, refdes: String, block: String)? in
                    guard let instanceID = item.string("block_instance")?.lowercased(),
                          let instance = instances.first(where: { $0.key.lowercased() == instanceID })?.value,
                          let child = instance.string("block") else { return nil }
                    return (instanceID, instance.string("refdes") ?? "", child.lowercased())
                }
                .sorted { $0.refdes.localizedStandardCompare($1.refdes) == .orderedAscending }
                for blockSymbol in blockSymbols {
                    try visit(blockSymbol.block, path: path + [blockSymbol.id])
                }
            }
        }
        try visit(top.uuid.lowercased(), path: [])

        for (block, refdesByComponent) in refdesChanges {
            try updateBlockFile(block) { json in
                var components = json["components"] as? JSONDictionary ?? [:]
                for (component, refdes) in refdesByComponent {
                    let key = components.keys.first { $0.lowercased() == component } ?? component
                    guard var item = components[key] as? JSONDictionary else { continue }
                    item["refdes"] = refdes
                    components[key] = item
                }
                json["components"] = components
            }
        }
        if mappings as NSDictionary != ((try blockFile(top.uuid))["block_instance_mappings"] as? JSONDictionary ?? [:]) as NSDictionary {
            try updateBlockFile(top.uuid) { $0["block_instance_mappings"] = mappings }
        }
        let changed = finalRefdes.filter { original[$0.key] != $0.value }.count
        return ["annotated": changed, "mode": mode, "order": order, "sheets": sheetNumber]
    }

    private static func emptySheet(named name: String, index: Int) -> JSONDictionary {
        var sheet: JSONDictionary = ["name": name, "index": index]
        for key in ["junctions", "net_lines", "net_labels", "net_ties", "bus_labels", "bus_rippers", "power_symbols",
                    "block_symbols", "symbols", "lines", "arcs", "texts", "pictures", "title_block_values"] {
            sheet[key] = JSONDictionary()
        }
        return sheet
    }

    /// Horizon's `BlockSymbol::create_template`: a 15 × 10 mm box with the
    /// instance's refdes above it and the block's name below.
    private static func blockSymbolTemplate(uuid: String, block: String) -> JSONDictionary {
        let halfWidth = 7_500_000, halfHeight = 5_000_000
        let corners = [(-halfWidth, halfHeight), (halfWidth, halfHeight), (halfWidth, -halfHeight), (-halfWidth, -halfHeight)]
        let junctionIDs = corners.map { _ in UUID().uuidString.lowercased() }
        var junctions = JSONDictionary(), lines = JSONDictionary(), texts = JSONDictionary()
        for (index, corner) in corners.enumerated() {
            junctions[junctionIDs[index]] = ["position": [corner.0, corner.1]]
            lines[UUID().uuidString.lowercased()] = ["from": junctionIDs[index], "to": junctionIDs[(index + 1) % 4], "layer": 0, "width": 0]
        }
        for (text, y) in [("$REFDES", halfHeight + 1_250_000), ("$NAME", -halfHeight - 1_250_000)] {
            texts[UUID().uuidString.lowercased()] = [
                "text": text, "placement": ["angle": 0, "mirror": false, "shift": [-halfWidth, y]],
                "size": 1_500_000, "layer": 0, "origin": "center", "font": "simplex", "width": 0, "from_smash": false
            ]
        }
        return ["type": "block_symbol", "uuid": uuid, "block": block, "junctions": junctions, "lines": lines,
                "arcs": JSONDictionary(), "texts": texts, "pictures": JSONDictionary(), "ports": JSONDictionary()]
    }

    /// Horizon's Add Block: a block with no parts, one empty sheet framed
    /// as the top's first sheet is, and the template symbol, filed as
    /// Horizon files them (`blocks/<uuid>/`). It shares the top block's net
    /// classes and power nets, as Horizon keeps them in step.
    private func addBlock(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let name = params.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw HorizontalDispatchError.invalidParams("add_block needs a \"name\".")
        }
        guard let top = knownBlocks.first(where: \.isTop) else {
            throw HorizontalDispatchError.failed("The project has no top block to add a block beside.")
        }
        let id = params.string("id")?.lowercased() ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: id) != nil else {
            throw HorizontalDispatchError.invalidParams("id must be a uuid.")
        }
        guard knownBlock(id) == nil else {
            throw HorizontalDispatchError.invalidParams("A block \(id) already exists.")
        }
        let blockPath = "blocks/\(id)/block.json"
        let schematicPath = "blocks/\(id)/schematic.json"
        let symbolPath = "blocks/\(id)/symbol.json"
        guard var blocks = try projectFile(project.blocksFilename) else {
            throw HorizontalDispatchError.failed("The project has no \(project.blocksFilename) to add the block to.")
        }

        let topBlock = try blockFile(top.uuid)
        let powerNets = topBlock.dictionaryMap("nets").filter { $0.value.bool("is_power") == true }
        var blockJSON: JSONDictionary = [
            "name": name, "uuid": id,
            "net_class_default": topBlock["net_class_default"] ?? Self.nullUUID,
            "net_classes": topBlock["net_classes"] ?? JSONDictionary(),
            "nets": powerNets as JSONDictionary,
            "project_meta": topBlock["project_meta"] ?? JSONDictionary()
        ]
        for key in ["components", "block_instances", "block_instance_mappings", "buses", "group_names", "tag_names"] {
            blockJSON[key] = JSONDictionary()
        }

        var sheet = Self.emptySheet(named: "First sheet", index: 1)
        var schematicJSON: JSONDictionary = ["type": "schematic_block", "uuid": UUID().uuidString.lowercased(), "block": id, "name": ""]
        if let topSchematic = top.schematicFilename.flatMap({ try? projectFile($0) }) ?? (top.uuid.lowercased() == blockID.lowercased() ? files["schematic"] : nil) {
            let firstSheet = topSchematic.dictionaryMap("sheets").values.min { ($0.int("index") ?? 0) < ($1.int("index") ?? 0) }
            if let frame = firstSheet?["frame"] { sheet["frame"] = frame }
            for key in ["annotation", "rules", "pdf_export_settings", "title_block_values", "group_tag_visible", "version"] {
                if let value = topSchematic[key] { schematicJSON[key] = value }
            }
        }
        schematicJSON["sheets"] = [UUID().uuidString.lowercased(): sheet]

        setProjectFile(blockPath, blockJSON)
        setProjectFile(schematicPath, schematicJSON)
        setProjectFile(symbolPath, Self.blockSymbolTemplate(uuid: UUID().uuidString.lowercased(), block: id))
        var entries = blocks["blocks"] as? JSONDictionary ?? [:]
        entries[id] = ["block_filename": blockPath, "schematic_filename": schematicPath, "symbol_filename": symbolPath]
        blocks["blocks"] = entries
        setProjectFile(project.blocksFilename, blocks)
        knownBlocks.append(HorizontalProjectBlock(uuid: id, blockFilename: blockPath, schematicFilename: schematicPath,
                                                  symbolFilename: symbolPath, isTop: false, name: name))
        return ["block": id, "name": name, "block_filename": blockPath, "schematic_filename": schematicPath, "symbol_filename": symbolPath,
                "note": "Its ports are nets set_net_port marks, which place_block_port draws on its symbol; add_block_instance uses it in another block."]
    }

    private func renameBlock(_ params: JSONDictionary) throws -> JSONDictionary {
        let target = try blockReference(params)
        guard let name = params.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw HorizontalDispatchError.invalidParams("rename_block needs a \"name\".")
        }
        try updateBlockFile(target.uuid) { $0["name"] = name }
        if let index = knownBlocks.firstIndex(where: { $0.uuid == target.uuid }) {
            knownBlocks[index].name = name
        }
        return ["block": target.uuid, "name": name]
    }

    /// Horizon removes a block only when nothing uses it, and never the top.
    /// Its files go with it.
    private func removeBlock(_ params: JSONDictionary) throws -> JSONDictionary {
        let target = try blockReference(params)
        guard !target.isTop else {
            throw HorizontalDispatchError.invalidParams("The top block can't be removed.")
        }
        guard target.uuid.lowercased() != blockID.lowercased() else {
            throw HorizontalDispatchError.invalidParams("A block can't remove itself; edit another block to remove it.")
        }
        let users = try knownBlocks.filter { other in
            try blockFile(other.uuid).dictionaryMap("block_instances").values.contains {
                $0.string("block")?.lowercased() == target.uuid.lowercased()
            }
        }
        guard users.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "\(target.displayName) is used in \(users.map(\.displayName).joined(separator: ", ")); remove those instances first."
            )
        }
        guard var blocks = try projectFile(project.blocksFilename) else {
            throw HorizontalDispatchError.failed("The project has no \(project.blocksFilename).")
        }
        var entries = blocks["blocks"] as? JSONDictionary ?? [:]
        if let key = entries.keys.first(where: { $0.lowercased() == target.uuid.lowercased() }) {
            entries.removeValue(forKey: key)
        }
        blocks["blocks"] = entries
        setProjectFile(project.blocksFilename, blocks)
        let removed = [target.blockFilename, target.schematicFilename, target.symbolFilename].compactMap { $0 }.filter { !$0.isEmpty }
        for path in removed { removeProjectFile(path) }
        // Horizon never prunes a mapping; one left for this block by an
        // instance since removed would name a block that is gone.
        if let top = knownBlocks.first(where: \.isTop),
           let mappings = try blockFile(top.uuid)["block_instance_mappings"] as? JSONDictionary {
            let kept = mappings.filter { ($0.value as? JSONDictionary)?.string("block")?.lowercased() != target.uuid.lowercased() }
            if kept.count != mappings.count {
                try updateBlockFile(top.uuid) { $0["block_instance_mappings"] = kept }
            }
        }
        knownBlocks.removeAll { $0.uuid == target.uuid }
        return ["block": target.uuid, "name": target.displayName, "files_removed": removed]
    }

    /// The edited block's symbol file, for the port ops: only a sub-block
    /// draws itself.
    private func editedSymbolPath() throws -> String {
        guard !isTopBlock, let path = knownBlock(blockID)?.symbolFilename, !path.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                isTopBlock ? "The top block has no symbol: ports belong to a block used inside another, so name one with block."
                    : "This block has no symbol file."
            )
        }
        return path
    }

    private static let portDirections: Set<String> = [
        "input", "output", "bidirectional", "open_collector", "power_input", "power_output", "passive", "not_connected"
    ]

    /// Horizon's "Is port" and Manage Port Nets: a net of a sub-block becomes
    /// one of its ports, which every block using it can wire, or stops being
    /// one, which takes its port off the symbol and its wiring off the
    /// sheets that drew it.
    private func setNetPort(_ params: JSONDictionary) throws -> JSONDictionary {
        guard !isTopBlock else {
            throw HorizontalDispatchError.invalidParams("The top block has no ports; name a block used inside another with block.")
        }
        let id = try netID(params)
        guard nets()[id]?.bool("is_power") != true else {
            throw HorizontalDispatchError.invalidParams("A power net can't be a port: power nets reach every block already.")
        }
        let isPort = params.bool("is_port") ?? true
        let direction = params.string("port_direction")
        if let direction, !Self.portDirections.contains(direction) {
            throw HorizontalDispatchError.invalidParams("port_direction must be one of \(Self.portDirections.sorted().joined(separator: ", ")).")
        }
        try updateNet(id) { net in
            net["is_port"] = isPort
            if let direction { net["port_direction"] = direction }
        }
        var change: JSONDictionary = ["net": id, "is_port": isPort]
        if let direction { change["port_direction"] = direction }
        if !isPort {
            change.merge(try dropPort(net: id)) { _, new in new }
        }
        return change
    }

    /// What Horizon's expand does to a port whose net is no longer one: it
    /// is erased from the symbol, the instances' connections to it go, and
    /// so do the wires that ended on it.
    private func dropPort(net: String) throws -> JSONDictionary {
        var change = JSONDictionary()
        let portID = HorizontalBlockSymbolPortID.uuid(forNet: net)
        if let path = try? editedSymbolPath(), var symbol = try projectFile(path),
           var ports = symbol["ports"] as? JSONDictionary,
           let key = ports.keys.first(where: { $0.lowercased() == portID }) {
            ports.removeValue(forKey: key)
            symbol["ports"] = ports
            setProjectFile(path, symbol)
            change["port_removed"] = true
        }
        var connections = 0, wires = 0
        for user in knownBlocks where user.uuid.lowercased() != blockID.lowercased() {
            let instances = try blockFile(user.uuid).dictionaryMap("block_instances")
                .filter { $0.value.string("block")?.lowercased() == blockID.lowercased() }
            guard !instances.isEmpty else { continue }
            let instanceIDs = Set(instances.keys.map { $0.lowercased() })
            try updateBlockFile(user.uuid) { json in
                var all = json["block_instances"] as? JSONDictionary ?? [:]
                for id in instances.keys {
                    guard var instance = all[id] as? JSONDictionary, var map = instance["connections"] as? JSONDictionary,
                          let key = map.keys.first(where: { $0.lowercased() == net.lowercased() }) else { continue }
                    map.removeValue(forKey: key)
                    instance["connections"] = map
                    all[id] = instance
                    connections += 1
                }
                json["block_instances"] = all
            }
            guard let portID else { continue }
            try updateSchematicFile(of: user.uuid) { schematic in
                var sheets = schematic["sheets"] as? JSONDictionary ?? [:]
                for (sheetID, value) in sheets {
                    guard var sheet = value as? JSONDictionary else { continue }
                    let symbols = Set(sheet.dictionaryMap("block_symbols")
                        .filter { instanceIDs.contains($0.value.string("block_instance")?.lowercased() ?? "") }
                        .keys.map { $0.lowercased() })
                    guard !symbols.isEmpty else { continue }
                    let doomed = Set(symbols.map { "\($0)/\(portID)" })
                    var lines = sheet["net_lines"] as? JSONDictionary ?? [:]
                    let before = lines.count
                    lines = lines.filter { _, value in
                        guard let line = value as? JSONDictionary else { return true }
                        return ![line.dictionary("from"), line.dictionary("to")].contains {
                            $0?.string("port").map { doomed.contains($0.lowercased()) } ?? false
                        }
                    }
                    guard lines.count != before else { continue }
                    wires += before - lines.count
                    sheet["net_lines"] = lines
                    sheets[sheetID] = sheet
                }
                schematic["sheets"] = sheets
            }
        }
        if connections > 0 { change["connections_removed"] = connections }
        if wires > 0 { change["wires_removed"] = wires }
        return change
    }

    /// Horizon's Place Port (MAP_PORT): one of the edited block's ports on
    /// its symbol, or moved there when the symbol has it. The port's uuid
    /// comes from its net, as Horizon derives it.
    private func placeBlockPort(_ params: JSONDictionary) throws -> JSONDictionary {
        let path = try editedSymbolPath()
        let net = try netID(params)
        guard nets()[net]?.bool("is_port") == true else {
            throw HorizontalDispatchError.invalidParams("\(nets()[net]?.string("name") ?? net) is not a port; set_net_port makes it one.")
        }
        guard let portID = HorizontalBlockSymbolPortID.uuid(forNet: net) else {
            throw HorizontalDispatchError.invalidParams("Net \(net) has no uuid to derive its port's from.")
        }
        guard var symbol = try projectFile(path) else {
            throw HorizontalDispatchError.notFound("Could not read the block's symbol \(path).")
        }
        var ports = symbol["ports"] as? JSONDictionary ?? [:]
        let key = ports.keys.first { $0.lowercased() == portID } ?? portID
        let existing = ports[key] as? JSONDictionary
        // Horizon's next port points the way the last one placed did.
        let previousOrientation = ports.values.compactMap { ($0 as? JSONDictionary)?.string("orientation") }.last
        var port = existing ?? ["length": 2_500_000, "name_orientation": "in_line", "orientation": previousOrientation ?? "right"]
        port["net"] = net
        if let x = params.double("x_mm"), let y = params.double("y_mm") {
            port["position"] = [Self.nanometres(x), Self.nanometres(y)]
        } else if existing == nil {
            throw HorizontalDispatchError.invalidParams("place_block_port needs \"x_mm\" and \"y_mm\" the first time.")
        }
        if let orientation = params.string("orientation") {
            guard ["up", "down", "left", "right"].contains(orientation) else {
                throw HorizontalDispatchError.invalidParams("orientation must be up, down, left or right.")
            }
            port["orientation"] = orientation
        }
        if let length = params.double("length_mm") { port["length"] = Self.nanometres(length) }
        if let nameOrientation = params.string("name_orientation") {
            guard ["in_line", "perpendicular", "horizontal"].contains(nameOrientation) else {
                throw HorizontalDispatchError.invalidParams("name_orientation must be in_line, perpendicular or horizontal.")
            }
            port["name_orientation"] = nameOrientation
        }
        ports[key] = port
        symbol["ports"] = ports
        setProjectFile(path, symbol)
        return ["port": key, "net": net, "created": existing == nil]
    }

    private func removeBlockPort(_ params: JSONDictionary) throws -> JSONDictionary {
        let path = try editedSymbolPath()
        let net = try netID(params)
        guard let portID = HorizontalBlockSymbolPortID.uuid(forNet: net),
              let symbol = try projectFile(path),
              (symbol["ports"] as? JSONDictionary)?.keys.contains(where: { $0.lowercased() == portID }) == true else {
            throw HorizontalDispatchError.notFound("The symbol draws no port for \(nets()[net]?.string("name") ?? net).")
        }
        return ["net": net].merging(try dropPort(net: net)) { _, new in new }
    }

    private func setBlockInstance(_ params: JSONDictionary) throws -> JSONDictionary {
        let id = try blockInstanceID(params)
        var instances = blockInstances()
        guard var instance = instances[id] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound("No block instance \(id).")
        }
        guard let refdes = params.string("refdes")?.trimmingCharacters(in: .whitespaces), !refdes.isEmpty else {
            throw HorizontalDispatchError.invalidParams("set_block_instance needs \"refdes\".")
        }
        instance["refdes"] = refdes
        instances[id] = instance
        block["block_instances"] = instances
        return ["block_instance": id, "refdes": refdes]
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

    /// An id edits that text or, naming none, makes one under it — see placeText.
    private func placeBoardText(_ params: JSONDictionary) throws -> JSONDictionary {
        let texts = try board()["texts"] as? JSONDictionary ?? [:]
        let reference = params.string("id")
        let existing = reference.flatMap { reference -> (id: String, json: JSONDictionary)? in
            guard let key = texts.keys.first(where: { $0.caseInsensitiveCompare(reference) == .orderedSame }),
                  let item = texts[key] as? JSONDictionary else {
                return nil
            }
            return (key, item)
        }
        if let reference, existing == nil {
            guard UUID(uuidString: reference) != nil, params.string("text") != nil, params.int("layer") != nil,
                  params.double("x_mm") != nil, params.double("y_mm") != nil else {
                throw HorizontalDispatchError.notFound(
                    "No board text \(reference). list_board_texts returns the ids; to make a text under a new id, "
                        + "give a UUID or a name with text, layer, x_mm and y_mm."
                )
            }
        }
        // A text a smash gave a package is the board's, to place as any
        // other; it stays the package's.
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
        if existing == nil, params.double("x_mm") == nil || params.double("y_mm") == nil {
            throw HorizontalDispatchError.invalidParams("place_board_text needs \"x_mm\" and \"y_mm\" the first time.")
        }
        if let shift = Self.textShift(placement, params) { placement["shift"] = shift }
        if let degrees = params.double("angle_deg") { placement["angle"] = Self.horizonAngle(degrees) }
        if let mirror = params.bool("mirror") { placement["mirror"] = mirror }
        item["placement"] = placement

        let id = existing?.id ?? reference?.lowercased() ?? UUID().uuidString.lowercased()
        try updateBoard { board in
            var texts = board["texts"] as? JSONDictionary ?? [:]
            texts[id] = item
            board["texts"] = texts
        }
        let (x, y) = Self.shift(placement)
        return ["id": id, "text": item.string("text") as Any, "layer": item.int("layer") as Any? as Any,
                "created": existing == nil, "x_mm": x / 1_000_000, "y_mm": y / 1_000_000]
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
        if kind == .label, let reference = params.string("id")?.lowercased(),
           let edited = try editSheetLabel(params, key: "bus_labels", id: reference) {
            return edited
        }
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
        let id = kind == .label ? try editObjectID(params) : UUID().uuidString.lowercased()
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

    /// `fields` merged into `rule`: an object into an object key by key, so a
    /// change to a rule's match or parameter set keeps the keys it doesn't
    /// name, and anything else in place of what was there. Returns the paths
    /// written, "match/net" for a key inside an object.
    private static func mergeRuleFields(_ fields: JSONDictionary, into rule: inout JSONDictionary, path: String = "") -> [String] {
        var written = [String]()
        for (key, value) in fields {
            let at = path.isEmpty ? key : "\(path)/\(key)"
            if let object = value as? JSONDictionary, var existing = rule[key] as? JSONDictionary {
                written += mergeRuleFields(object, into: &existing, path: at)
                rule[key] = existing
            } else {
                rule[key] = value
                written.append(at)
            }
        }
        return written.sorted()
    }

    private func addRule(_ params: JSONDictionary) throws -> JSONDictionary {
        let kind = try ruleKind(params)
        let id = try ruleAddress(params, kind: kind, mustExist: false)
        let fields = params["fields"] as? JSONDictionary ?? [:]
        var created: JSONDictionary = [:]
        var written = [String]()
        try updateRules { rules in
            // After every rule of its kind, which is where the app's editor
            // puts a new one: by order, not count, since a batch may have
            // moved one of them already.
            let family = kind.isMulti ? (rules.dictionary(kind.rawValue) ?? [:]) : [:]
            let order = family.values.compactMap { ($0 as? JSONDictionary)?.int("order") }.max().map { $0 + 1 } ?? 0
            // The defaults the app's own rules editor would give it, so a rule
            // added here is the rule a person would have got.
            created = kind.defaultRule(context: ruleContext(), order: order)
            // A via rule gives the vias it matches their padstack, and the
            // editor leaves the choice to the user; here it is the padstack
            // the board's via rules already use, else its vias'.
            if kind == .via, (created.string("padstack") ?? "").isEmpty {
                let existing = family.values.compactMap { $0 as? JSONDictionary }
                    .sorted { ($0.int("order") ?? 0) < ($1.int("order") ?? 0) }
                    .compactMap { $0.string("padstack") }.first { !$0.isEmpty && $0 != Self.nullUUID }
                if let padstack = existing ?? project.board?.viaTemplate?.padstackID { created["padstack"] = padstack }
            }
            written = Self.mergeRuleFields(fields, into: &created)
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
        var change: JSONDictionary = ["kind": kind.rawValue, "rule_id": id as Any? as Any, "rule": created, "created": true]
        if !written.isEmpty { change["set"] = written }
        if kind == .via { change.merge(try rederiveRuleVias()) { _, new in new } }
        return change
    }

    private func setRule(_ params: JSONDictionary) throws -> JSONDictionary {
        let kind = try ruleKind(params)
        let id = try ruleAddress(params, kind: kind, mustExist: true)
        guard let fields = params["fields"] as? JSONDictionary, !fields.isEmpty else {
            throw HorizontalDispatchError.invalidParams("set_rule needs \"fields\": what to change.")
        }
        var merged: JSONDictionary = [:]
        var written = [String]()
        try updateRules { rules in
            if kind.isMulti {
                var family = rules.dictionary(kind.rawValue) ?? [:]
                guard let id, var rule = family[id] as? JSONDictionary else {
                    throw HorizontalDispatchError.notFound("No \(kind.rawValue) rule to change.")
                }
                // Merged, not replaced, all the way down: a caller changing one
                // clearance, or a match's net, should not have to restate the
                // rest of the rule to keep it.
                written = Self.mergeRuleFields(fields, into: &rule)
                merged = rule
                family[id] = rule
                rules[kind.rawValue] = family
            } else {
                guard var rule = rules.dictionary(kind.rawValue) else {
                    throw HorizontalDispatchError.notFound("The board has no \(kind.rawValue) rule; add_rule makes one.")
                }
                written = Self.mergeRuleFields(fields, into: &rule)
                merged = rule
                rules[kind.rawValue] = rule
            }
        }
        var change: JSONDictionary = ["kind": kind.rawValue, "rule_id": id as Any? as Any, "rule": merged, "changed": written]
        if kind == .via { change.merge(try rederiveRuleVias()) { _, new in new } }
        return change
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
        var change: JSONDictionary = ["kind": kind.rawValue, "rule_id": id as Any? as Any, "removed": true]
        if kind == .via { change.merge(try rederiveRuleVias()) { _, new in new } }
        return change
    }

    // MARK: - Project metadata and export settings

    /// The title-block values live in the top block, where the board and
    /// Horizon read them. The schematic may keep copies of its own, once for
    /// the whole schematic and once per sheet, and a copy wins on the sheets
    /// it covers; so a key a copy repeats changes there too, or the sheets
    /// would keep the old value while the board showed the new one.
    private func setProjectMeta(_ params: JSONDictionary) throws -> JSONDictionary {
        guard isTopBlock else {
            throw HorizontalDispatchError.invalidParams("The title-block values are the project's, kept in the top block. Leave \"block\" out.")
        }
        guard let values = params["values"] as? JSONDictionary, !values.isEmpty else {
            throw HorizontalDispatchError.invalidParams("set_project_meta needs \"values\": the keys to set.")
        }
        var changes = HorizontalTitleBlockChanges()
        for (key, value) in values {
            guard !key.trimmingCharacters(in: .whitespaces).isEmpty, !key.contains("$") else {
                throw HorizontalDispatchError.invalidParams("\"\(key)\" is not a title-block key; $\(key) has to name it.")
            }
            guard value is NSNull || value is String else {
                throw HorizontalDispatchError.invalidParams("\(key) must be a string, or null to remove it.")
            }
            // Trimmed, and blank means gone, as the app's own editor has it.
            let one = HorizontalTitleBlockChanges(key: key, value: value as? String)
            changes.set.merge(one.set) { _, new in new }
            changes.removed.formUnion(one.removed)
        }
        var meta = block["project_meta"] as? JSONDictionary ?? [:]
        var changed = Set(changes.patch(&meta, onlyExisting: false))
        if !changed.isEmpty {
            if meta.isEmpty { block.removeValue(forKey: "project_meta") } else { block["project_meta"] = meta }
        }
        var copies = [String]()
        if var schematic = files["schematic"] {
            let patched = changes.patchCopies(inSchematic: &schematic)
            if !patched.changed.isEmpty {
                files["schematic"] = schematic
                dirty.insert("schematic")
                changed.formUnion(patched.changed)
                copies = patched.copies
            }
        }
        return ["project_meta": meta, "changed": changed.sorted(), "schematic_copies": copies]
    }

    /// Merges fields into the export settings Horizon EDA keeps for one kind
    /// of output. Only fields the settings already hold, each kept to the type
    /// it has: Horizon reads these back strictly, and a misspelt key or a
    /// number where it wants a string would stop it opening the project.
    private func setExportSettings(_ params: JSONDictionary) throws -> JSONDictionary {
        let location = try HorizontalStoredExportSettings.location(params.string("kind"))
        guard isTopBlock else {
            throw HorizontalDispatchError.invalidParams("Export settings are the project's, kept with the top block. Leave \"block\" out.")
        }
        guard let fields = params["fields"] as? JSONDictionary, !fields.isEmpty else {
            throw HorizontalDispatchError.invalidParams("set_export_settings needs \"fields\": what to change.")
        }
        guard var file = files[location.file] else {
            throw HorizontalDispatchError.notFound("The project has no \(location.file).")
        }
        guard var settings = file[location.key] as? JSONDictionary else {
            throw HorizontalDispatchError.notFound(
                "The project keeps no \(location.kind) settings (\(location.key)) yet. Horizon EDA writes them the first time its export dialog is used; Horizontal's own export does not need them."
            )
        }
        for key in fields.keys.sorted() {
            let value = fields[key]!
            guard let current = settings[key] else {
                throw HorizontalDispatchError.invalidParams(
                    "\(location.kind) settings have no field \(key). They hold: \(settings.keys.sorted().joined(separator: ", "))."
                )
            }
            if let problem = HorizontalStoredExportSettings.mismatch(current, value) {
                throw HorizontalDispatchError.invalidParams("\(key) must be \(problem), as it is now.")
            }
            settings[key] = value
        }
        file[location.key] = settings
        files[location.file] = file
        dirty.insert(location.file)
        return ["kind": location.kind, "key": location.key, "changed": fields.keys.sorted(),
                "values": fields]
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
    private static let emptySheetKeys = HorizontalSchematic.sheetCollectionKeys

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
        if params.keys.contains("frame") {
            frame = try resolvedFrame(params["frame"])?.id
        } else {
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

    /// A sheet's frame, set or taken away. Horizon's sheet properties choose
    /// it from the pool; here it is named by uuid.
    private func setSheetFrame(_ params: JSONDictionary) throws -> JSONDictionary {
        guard params["sheet"] != nil else {
            throw HorizontalDispatchError.invalidParams("set_sheet_frame needs sheet: an index, name or uuid.")
        }
        guard params.keys.contains("frame") else {
            throw HorizontalDispatchError.invalidParams("set_sheet_frame needs frame: a pool frame uuid, or \"none\".")
        }
        let id = try sheetID(params)
        let frame = try resolvedFrame(params["frame"])
        let previous = try sheetsInOrder().first { $0.id == id }?.json.string("frame")
        try updateSheet(id) { sheet in
            if let frame {
                sheet["frame"] = frame.id
            } else {
                sheet.removeValue(forKey: "frame")
            }
        }
        return ["sheet": id, "frame": frame.map { $0.id as Any } ?? NSNull(), "frame_name": frame.map { $0.name as Any } ?? NSNull(),
                "previous_frame": previous.map { $0 as Any } ?? NSNull()]
    }

    /// The frame a `frame` parameter names: nil for "none" or null, else a
    /// frame the project pool holds where a sheet's frame is drawn from
    /// (`frames/cache/<uuid>.json`, or the project's own anywhere else under
    /// `frames/`). One that is not there is refused with where it is, since a
    /// sheet naming it would draw no frame at all.
    private func resolvedFrame(_ value: Any?) throws -> (id: String, name: String)? {
        if value == nil || value is NSNull { return nil }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw HorizontalDispatchError.invalidParams("frame must be a pool frame uuid or \"none\".")
        }
        if text.caseInsensitiveCompare("none") == .orderedSame { return nil }
        guard UUID(uuidString: text) != nil else {
            throw HorizontalDispatchError.invalidParams("frame must be a pool frame uuid or \"none\".")
        }
        let frameID = text.lowercased()
        guard let poolURL else {
            throw HorizontalDispatchError.failed("The project has no pool directory, so it has no frames.")
        }
        if let data = try store.read(HorizontalSchematic.frameURL(frameID, poolURL: poolURL)),
           let json = try? JSONHelper.loadDictionary(from: data), json.string("type") == "frame" {
            return (frameID, json.string("name") ?? "")
        }
        if let url = HorizontalProjectPoolIndex.url(.frame, frameID, poolURL: poolURL),
           let data = try store.read(url),
           let json = try? JSONHelper.loadDictionary(from: data), json.string("type") == "frame" {
            return (frameID, json.string("name") ?? "")
        }
        // The project's own frame, outside the cache, that the index (which
        // reads the disk) can't see yet: one written in this batch, or into a
        // live document since it was saved (field finding 151).
        for url in snapshot?.jsonFiles(under: poolURL.appendingPathComponent("frames")) ?? [] where !url.path.contains("/frames/cache/") {
            if let json = snapshot?.json(at: url), json.string("type") == "frame", json.string("uuid")?.lowercased() == frameID {
                return (frameID, json.string("name") ?? "")
            }
        }
        let projectPool = HorizontalPoolLibrary.canonicalURL(poolURL).path
        let holder = HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: poolURL).lazy.compactMap { url in
            HorizontalPoolLibrary.items(inPool: url, poolName: HorizontalPoolRegistryStore.poolInfo(at: url).name)
                .first { $0.category == .frame && $0.uuid == frameID }
        }.first
        guard let holder else {
            throw HorizontalDispatchError.notFound(
                "No frame \(frameID) in the project pool or the pools it draws from. search_pool with kind frame lists the frames there are."
            )
        }
        let name = holder.name.isEmpty ? frameID : "\(holder.name) (\(frameID))"
        if holder.poolURL.standardizedFileURL.path == projectPool {
            throw HorizontalDispatchError.notFound(
                "Frame \(name) is in the project pool at \(holder.url.path), but a sheet's frame is drawn from the pool's frames/ directory, where it is not."
            )
        }
        throw HorizontalDispatchError.notFound(
            "Frame \(name) is in \(holder.poolName), not the project pool, which is where a sheet's frame is drawn from. "
                + "Bring it in first: get_pool_item reads it, and pool_write puts it in the project pool, or pass it as pool_items in this apply_ops."
        )
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

    /// The block's nets as the rules' matches read them: name and class.
    private func ruleNetDetails() -> [String: HorizontalNetDetails] {
        let classes = block.dictionaryMap("net_classes")
        var details = [String: HorizontalNetDetails]()
        for (id, net) in nets() {
            let classID = net.string("net_class")?.lowercased()
            details[id.lowercased()] = HorizontalNetDetails(
                id: id.lowercased(), name: net.string("name") ?? "", netClassID: classID,
                netClassName: classID.flatMap { key in classes.first { $0.key.lowercased() == key }?.value.string("name") })
        }
        return details
    }

    /// The via rule that shapes a via on `net`: the first enabled one by order
    /// whose match takes the net, as Horizon's BoardRules looks it up for a via
    /// whose source is the rules. Its id comes with it.
    private func viaRule(net: String?) throws -> (id: String, rule: JSONDictionary)? {
        let family = (try board()["rules"] as? JSONDictionary ?? [:]).dictionaryMap("via")
        let details = ruleNetDetails()
        return family.filter { $0.value.bool("enabled") ?? true }
            .sorted { ($0.value.int("order") ?? 0, $0.key) < ($1.value.int("order") ?? 0, $1.key) }
            .first { HorizontalRuleMatch(json: $0.value.dictionary("match")).matches(netID: net?.lowercased(), netDetails: details) }
            .map { ($0.key, $0.value) }
    }

    /// What a new via takes its shape from, as Horizon's via sources have it:
    /// - a board via definition, named by `definition`;
    /// - its own size (`diameter_mm`, `hole_mm`) or `padstack`, which is local;
    /// - otherwise the via rules: the padstack and parameters of the rule that
    ///   matches its net, written in, since that is what Horizon gives it.
    /// A board with no via rule gets the padstack and size its other vias have.
    private func viaShape(net: String, _ params: JSONDictionary) throws -> JSONDictionary {
        let rules = try board()["rules"] as? JSONDictionary ?? [:]
        if let reference = params.string("definition") {
            let definitions = rules.dictionary("via_definitions")?.dictionaryMap("via_definitions") ?? [:]
            let matches = definitions.filter {
                $0.key.caseInsensitiveCompare(reference) == .orderedSame
                    || ($0.value.string("name") ?? "").caseInsensitiveCompare(reference) == .orderedSame
            }
            guard matches.count == 1, let (id, definition) = matches.first else {
                let names = definitions.values.compactMap { $0.string("name") }.sorted()
                throw HorizontalDispatchError.notFound(
                    "No via definition \(reference) on the board. Definitions: \(names.isEmpty ? "none" : names.joined(separator: ", ")).")
            }
            guard params["diameter_mm"] == nil, params["hole_mm"] == nil, params["padstack"] == nil else {
                throw HorizontalDispatchError.invalidParams("A via definition sets the padstack and size; pass definition alone.")
            }
            return ["source": "definition", "definition": id, "padstack": definition.string("padstack") ?? "",
                    "parameter_set": definition.dictionary("parameters") ?? [:]]
        }
        let ruled = try viaRule(net: net)
        let template = project.board?.viaTemplate
        if params["diameter_mm"] != nil || params["hole_mm"] != nil || params["padstack"] != nil {
            var parameters = ruled?.rule.dictionary("parameter_set") ?? [
                "via_diameter": Int(template?.diameter ?? 500_000), "hole_diameter": Int(template?.holeDiameter ?? 200_000)
            ]
            if let diameter = params.double("diameter_mm") { parameters["via_diameter"] = Self.nanometres(diameter) }
            if let hole = params.double("hole_mm") { parameters["hole_diameter"] = Self.nanometres(hole) }
            guard let padstack = params.string("padstack")?.lowercased() ?? ruled?.rule.string("padstack") ?? template?.padstackID else {
                throw HorizontalDispatchError.invalidParams("The board has no via rule or via to take a padstack from, so pass \"padstack\".")
            }
            return ["source": "local", "padstack": padstack, "parameter_set": parameters]
        }
        if let ruled, let padstack = ruled.rule.string("padstack"), !padstack.isEmpty, padstack != Self.nullUUID {
            return ["source": "rules", "padstack": padstack, "parameter_set": ruled.rule.dictionary("parameter_set") ?? [:], "rule": ruled.id]
        }
        guard let template else {
            throw HorizontalDispatchError.invalidParams(
                "The board has no via rule and no via to copy a padstack from, so pass \"padstack\" — a via padstack uuid from search_pool."
            )
        }
        return ["source": "local", "padstack": template.padstackID,
                "parameter_set": ["via_diameter": Int(template.diameter), "hole_diameter": Int(template.holeDiameter)]]
    }

    /// Vias that take their shape from the via rules, given the padstack and
    /// parameters of the rule that now matches their net, after the rules
    /// change: what Horizon gives them when it opens the board, so the file
    /// and everything read from it agree. Counted in the reply.
    private func rederiveRuleVias() throws -> JSONDictionary {
        guard isTopBlock, files["board"] != nil else { return [:] }
        let loaded = Dictionary((project.board?.vias ?? []).map { ($0.id.lowercased(), $0.netID?.lowercased()) }, uniquingKeysWith: { first, _ in first })
        let junctions = try board().dictionaryMap("junctions")
        var vias = try board().dictionaryMap("vias")
        var changed = [String]()
        for (id, var via) in vias {
            let source = via.string("source") ?? ((via.bool("from_rules") ?? true) ? "rules" : "local")
            guard source == "rules" else { continue }
            let net = via.string("net_set")?.lowercased()
                ?? via.string("junction").flatMap { key in junctions.first { $0.key.lowercased() == key.lowercased() }?.value.string("net")?.lowercased() }
                ?? loaded[id.lowercased()] ?? nil
            guard let rule = try viaRule(net: net)?.rule, let padstack = rule.string("padstack"), !padstack.isEmpty, padstack != Self.nullUUID else { continue }
            let parameters = rule.dictionary("parameter_set") ?? [:]
            guard via.string("padstack")?.lowercased() != padstack.lowercased()
                    || !NSDictionary(dictionary: via.dictionary("parameter_set") ?? [:]).isEqual(to: parameters) else { continue }
            via["padstack"] = padstack
            via["parameter_set"] = parameters
            vias[id] = via
            changed.append(id)
        }
        guard !changed.isEmpty else { return [:] }
        try updateBoard { $0["vias"] = vias }
        return ["vias_rederived": changed.count]
    }

    private func placeVia(_ params: JSONDictionary) throws -> JSONDictionary {
        guard let x = params.double("x_mm"), let y = params.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("place_via needs \"x_mm\" and \"y_mm\".")
        }
        guard let reference = params.string("net") else {
            throw HorizontalDispatchError.invalidParams("place_via needs \"net\": a via carries one.")
        }
        let net = try netID(reference: reference)
        for key in ["diameter_mm", "hole_mm"] {
            if let value = params.double(key), value <= 0 { throw HorizontalDispatchError.invalidParams("\(key) must be above zero.") }
        }
        let shape = try viaShape(net: net, params)
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
        let source = shape.string("source") ?? "rules"
        let parameters = shape.dictionary("parameter_set") ?? [:]
        try updateBoard { board in
            var vias = board["vias"] as? JSONDictionary ?? [:]
            // The fields Via::serialize writes. net_set pins the net onto the
            // via, so it seeds propagation like a pad instead of waiting for
            // copper to reach it.
            var via: JSONDictionary = ["junction": junction, "padstack": shape.string("padstack") ?? "", "source": source,
                                       "from_rules": source == "rules", "locked": false, "net_set": net, "parameter_set": parameters]
            if let definition = shape.string("definition") { via["definition"] = definition }
            vias[id] = via
            board["vias"] = vias
        }
        var change: JSONDictionary = ["via": id, "junction": junction, "net": net, "padstack": shape.string("padstack") ?? "",
                                      "source": source]
        if let diameter = parameters["via_diameter"] { change["diameter_mm"] = HorizontalDispatchJSON.mm(JSONHelper.doubleValue(diameter)) }
        if let hole = parameters["hole_diameter"] { change["hole_mm"] = HorizontalDispatchJSON.mm(JSONHelper.doubleValue(hole)) }
        if let rule = shape.string("rule") { change["via_rule"] = rule }
        if let definition = shape.string("definition") { change["definition"] = definition }
        return change
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

    /// A text's shift after x_mm and y_mm, or nil when neither is given. A
    /// text that is there takes either alone and keeps its other coordinate,
    /// so x_mm by itself moves it sideways; the ops make a new text only with
    /// both.
    private static func textShift(_ placement: JSONDictionary, _ params: JSONDictionary) -> [Int]? {
        let x = params.double("x_mm"), y = params.double("y_mm")
        guard x != nil || y != nil else { return nil }
        let (oldX, oldY) = shift(placement)
        return [x.map(nanometres) ?? Int(oldX.rounded()), y.map(nanometres) ?? Int(oldY.rounded())]
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

/// Where Horizon EDA keeps each export's settings in a project: the file, as
/// the editor loads it, and the key in it. Horizontal's own export names its
/// files after the project file and reads none of these; they are kept so
/// the project exports the same from Horizon.
enum HorizontalStoredExportSettings {
    struct Location {
        var kind: String
        var file: String
        var key: String
    }

    static let all: [Location] = [
        Location(kind: "gerber", file: "board", key: "fab_output_settings"),
        Location(kind: "odb", file: "board", key: "odb_output_settings"),
        Location(kind: "pick_and_place", file: "board", key: "pnp_export_settings"),
        Location(kind: "board_step", file: "board", key: "step_export_settings"),
        Location(kind: "board_pdf", file: "board", key: "pdf_export_settings"),
        Location(kind: "bom", file: "block", key: "bom_export_settings"),
        Location(kind: "schematic_pdf", file: "schematic", key: "pdf_export_settings")
    ]

    /// The export tool's names for the same outputs.
    private static let aliases = ["gerbers": "gerber", "pnp": "pick_and_place", "step": "board_step", "board_drawing": "board_pdf"]

    static func location(_ kind: String?) throws -> Location {
        let known = all.map(\.kind).joined(separator: ", ")
        guard let kind, !kind.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Pass \"kind\": one of \(known).")
        }
        let name = aliases[kind.lowercased()] ?? kind.lowercased()
        guard let found = all.first(where: { $0.kind == name }) else {
            throw HorizontalDispatchError.invalidParams("Unknown export settings kind \(kind). Known: \(known).")
        }
        return found
    }

    /// What a new value would have to be to stand where the current one does,
    /// or nil when it already is. Null stands for anything.
    static func mismatch(_ current: Any, _ value: Any) -> String? {
        func isBool(_ item: Any) -> Bool { (item as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
        switch current {
        case is NSNull:
            return nil
        case _ where isBool(current):
            return isBool(value) ? nil : "true or false"
        case let number as NSNumber:
            guard let new = value as? NSNumber, !isBool(value), new.doubleValue.isFinite else { return "a number" }
            let whole = number.doubleValue.rounded() == number.doubleValue
            return whole && new.doubleValue.rounded() != new.doubleValue ? "a whole number" : nil
        case is String:
            return value is String ? nil : "a string"
        case is JSONDictionary:
            return value is JSONDictionary ? nil : "an object"
        case is [Any]:
            return value is [Any] ? nil : "an array"
        default:
            return nil
        }
    }
}
