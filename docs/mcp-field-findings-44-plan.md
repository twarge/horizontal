# MCP field findings 44: the open list

Planning baseline: `140127e`. Written October 17, 2026. These are the items
still open in `horizontal-mcp-notes.md`:
- **102 and 103:** from the Billo edits.
- **106–119:** from the Cinnamon edits on October 14. 119 is closed as out
  of scope.
- **132–135:** from the Billo SYNC/FREQ edits on October 17.
- **136–139:** added during this round by the session editing Billo.

## Findings and changes

102. **Parts couldn't be moved with their wiring.**
     - **`move_symbols` (new op):** `symbols` are instance ids, or components
       standing for each of their gates on the sheet. It also takes `dx_mm`,
       `dy_mm`, an optional `to_sheet`, extra `junctions` and `texts`.
     - **What a junction belongs to:** the wiring is read as a graph of
       junctions, each marked with whether it touches a moving pin or an
       anchor. Anchors are pins that stay, ports, bus rippers, bus labels and
       net ties.
       - An island of wiring with no anchor moves whole.
       - In wiring that does reach an anchor, the dead ends are peeled back
         to the wiring that joins anchors. Each peeled branch that reaches a
         moving pin moves; the branch point stays.
     - **What follows:**
       - Labels and power symbols ride on their junctions.
       - A symbol's smashed texts move with it.
       - A wire from something that moves to something that stays stretches
         (`stretched_net_lines`).
     - **Onto another sheet:** the symbols, junctions, wires, labels, power
       symbols, net ties and texts go across. A wire that reached wiring that
       stays is cut, and `cut` names each end that went: its net, the junction
       or pin, and its new position, for a label there. Junctions the cut
       leaves holding nothing go.
     - **`place_junction` moves a junction:** given the id of one that is
       there, it moves it, and its wires, labels and power symbols follow.
       `net` is then optional and has to be the junction's own. A junction
       already at the target point is refused.
103. **Edit replies were large.** Compact replies already gave ids and
     counts per change. A compact dry run now also leaves `normalized_ops`
     out: the commit sends the same ops with the `plan_digest` and installs
     the staged plan (its key no longer includes `expected_revision`, see
     116). `verbose` still echoes them. Names a batch gave come back in
     `handles`.
106. **A live document refused every write.**
     - **The cause:** found by a read-only investigation, then checked here.
       - A `.hprj` document starts as its `.hprj` alone, since a
         `ReadConfiguration` has no URL. `ProjectDocumentView.loadProject`
         gathers the tree in a `.task(id:)` keyed on the URL.
       - A Revert, or AppKit reading the file again in place, hands the
         document a single-file archive at the same URL, so the task never
         runs again.
       - Edits then failed on files the archive lacked: "board.json is not a
         valid project-relative path", recorded as a load diagnostic.
       - `render_sheet` materialized the single file and found no sheets,
         while `open_project` reported the workspace's model.
     - **In the window:** `needsProjectTree` (a writable `.hprj` document
       holding a regular file) triggers `loadProject` when it turns true. It
       replaces the read-only unlock trigger, which it also covers. A load
       whose result `completeLoading` refuses reads again when the document
       holds a single file once more, instead of leaving the window loading.
     - **In the live channel:**
       - Such an entry is marked `holdsProjectFileOnly`.
       - Its reads come from the files on disk. It can hold no edits of its
         own, since every edit needs the tree.
       - Edits are refused with `RECOVERY_REQUIRED`, naming the `.hprj` and
         saying what to do.
       - `open_project` says `holds_project_file_only`.
       - The live archive's own id is kept apart (`liveArchiveID`), so the
         disk capture isn't redone on every request.
     - **Also fixed:** a read-only live `.hprj` document (every Release
       build) is the same case, and read nothing; it now reads from disk.
107. **Copper that shorted two nets went unreported.**
     - **`check`, category "copper", level error:**
       - **"Copper joins two nets":** tracks and vias reaching pads of more
         than one net, from the editor's connectivity graph. The graph is
         factored out of `HorizontalBoardConnectivity.recompute` and walked by
         a new `shorts`. The finding names each net's pads, the tracks, and
         where one starts.
       - **"Plane runs over a pad on another net":** a pad on another net
         whose centre lies inside a poured fragment, tested even-odd as the
         airwire pass does.
     - **Warnings on `connect` and `disconnect`, and after `remap_part`:**
       when a pin's net changes and its pad has tracks carrying another net,
       `warnings` names the pad, the nets and the tracks, and says how to
       find the copper.
108. **Copper couldn't be listed by component or pad.**
     - **`list_tracks`:** takes `component`, `pads` (by name or uuid) and
       `connected`. `connected` follows junctions out to the next pad.
     - **`list_vias`:** takes `component`, meaning vias inside its courtyard,
       else its pads' bounds.
109. **A reused junction's handle named nothing.**
     - **The cause:** `place_junction` reusing a junction at the point
       returned that junction, while later ops still used the handle's fresh
       UUIDv5.
     - **Now:** the editor keeps `reusedIDs` and rewrites later ops through
       it.
     - **The reply:**
       - `handles` maps the name to the junction reused, and
         `reused_handles` lists it.
       - The change says `reused: true` and `requested_id`.
       - The normalized ops replay.
110. **The contract still said a live edit waited for `save`.**
     - **Durability:** a commit's `durability` is `"document"`. The Python
       schema still accepts the old `"unsaved_document"` from an older app.
     - **`save`:** says `saved: true` once the file verifies, and a new
       `wrote` says whether the call wrote anything.
     - **Text:** the comments in `HorizontalDocumentSaving`,
       `HorizontalLiveDocument.save` and `project_info` now describe autosave.
       So do the `save` tool description, automation.md, mcp-analysis.md and
       the Python README.
111. **`remap_part` couldn't let go of copper.**
     - **Pads by name:** a routed pad whose pin settles nothing goes to the
       target pad of its name.
     - **`copper`:** `"refuse"` (the default) names every stranded pad by
       name before anything changes. `"drop"` removes their tracks and the
       junctions they leave.
     - **The reply:** lists the vias under the old footprint.
112. **Removing a symbol stranded its wiring.**
     - **Now:** `remove_symbol` and `remove_component` take the wiring the
       removal turned into debris. They compare `HorizontalSchematicDebris`
       before and after on each sheet drawing the part.
       - **What goes:** islands that now reach no pin, with their labels and
         power symbols, and new dead ends, with the junctions they stood on.
       - **What stays:** what was debris before, which is left for
         `prune_sheet`.
     - **Options:** `keep_wiring` leaves it all. `wiring_removed` counts what
       went.
113. **An unnamed net could only be named by its full UUID.** Nets and
     components (in ops, `get_net`, `get_component`, and the net and
     component filters) take eight or more leading hex digits, with or
     without dashes and with a copied "…", when one id begins that way.
     Several matching is an `AMBIGUOUS_SELECTOR` with candidates. Names and
     whole ids are tried first. `existingNetID` keeps an ambiguous name from
     reading as "make a new net".
114. **Compact wire rows on unnamed nets said only `net_name: ""`.** Those
     rows now carry `net`, the uuid. On Cinnamon's DAC sheet most wires are
     on such nets. Its DAC Output wires do read their name, so this was the
     unnamed nets.
115. **`get_component` gave no pin positions.** Each drawn pin gives `at`:
     where it ends on the sheet, in mm, and `points`, which way it leaves
     its symbol. Both are read from the loaded sheet, so turns and mirrors
     are already applied. Where a gate is drawn more than once, each end
     names its `symbol_instance`.
116. **Dry runs needed `expected_revision` and `operation_id`.**
     - **Engine:** a dry run without a revision is checked against the
       revision as it is (`requireRevision(currentWhenMissing:)`).
     - **MCP:** both parameters are optional in every mutation tool's schema
       and required to commit.
     - **Python client:** a dry run given no revision leaves it out, so a
       summary read before someone else's edit doesn't get it refused.
117. **Ops named their target differently.** Every op that acts on one thing
     by a field of its own also takes `id`: `remove_net_line`,
     `set_net_line_endpoint`, `remove_junction`, `remove_track`,
     `set_track_width`, `remove_via`, `remove_polygon`, `remove_plane`,
     `remove_hole`, `remove_keepout`, `remove_dimension`, `remove_bus`,
     `remove_net_tie`, `remove_block_instance` and `remove_block_symbol`.
     Giving both, differing, is refused. Batch names resolve through `id`.
118. **A label placed on a wire didn't join it.**
     - **Splitting:** `place_net_label` and `place_power_symbol` at a point
       inside a wire of their net split the wire there, as the app's tool
       does, and say `split_net_line`.
     - **Refused:** a point on a wire of another net, or a pin's end.
     - **`check`:** a warning about a stretch of wiring (Label missing, Power
       sym missing and the rest) names its wires in `net_lines`.
119. **Closed, out of scope.** `analyze_noise` still needs a model with
     evidence for every amplifier. Putting noise parameters on pool parts, so
     a scenario could name parts instead, is out of scope for Horizontal, by
     the user's decision, so nothing changes.
132. **`place_via` ignored the via rules.**
     - **The default:** a new via takes the padstack and parameter set of
       the first enabled via rule matching its net (`viaRule`, through
       `HorizontalRuleMatch`). Ties in order are broken by id. It is written
       with `source: "rules"`, `from_rules`, `locked` and `net_set`, as
       `Via::serialize` writes them.
     - **Alternatives:** `definition` takes a board via definition by name or
       uuid. `diameter_mm`, `hole_mm` or `padstack` make the via's shape its
       own (`source: "local"`). A board with no via rule copies its other
       vias.
     - **Rule changes:** `add_rule`, `set_rule` and `remove_rule` on via
       rules re-derive every rule-shaped via (`vias_rederived`).
     - **`list_vias`:** marks a rule-shaped via with no parameters
       `unresolved`.
134. **`add_rule` could make a tied, padstack-less via rule.**
     - **Making it:** `add_rule` takes `fields`, merged into the defaults. A
       new rule is ordered after the highest order of its kind, not by
       count. A via rule takes the padstack the board's via rules already
       use, else its vias'.
     - **The validator:** gives "Via rule has no padstack" as an error, which
       refuses the write.
135. **`set_rule` replaced nested objects.** Fields merge an object into an
     object key by key, at any depth. `changed` lists the paths written
     (`parameter_set/via_diameter`).
133. **A live document couldn't be found by its folder.** `project_file`
     resolves a folder to the `.hprj` it holds, as the engine's disk open
     picks it: the one named after the folder, else the first by name. It is
     used in `open`, `open_project`, `live_state` and context matching.
136. **The app didn't save a label's orientation.**
     `patchSchematicNetLabels` and `patchSchematicBusLabels` now write
     `orientation`.
137. **`remap_part` couldn't fold two drawn gates into one.**
     - **Mapping:** a target entity with one gate takes every old gate's pins
       by name.
     - **Symbols:** drawn gates landing on one target gate keep the symbol of
       the one with most pins. The others come off with their wiring
       (`symbols_removed`, `wiring_removed`), and `pins_to_wire` names their
       pins.
     - **The error:** a gate whose pins land on several gates now names
       `remove_symbol`.
138. **`remap_part` needed an identity pad map on the same package.** Old
     and new parts on one package keep every pad (`pads_kept`).
139. **`board.package_id` read null after a remap onto a `pool_write`
     part.**
     - **Now:** the design index takes the part's package when the board's
       placement names none.
     - **`clean_up_project_pool`:** a compact reply naming what it removes
       lists only those items, with `unused_count`.

## Tests

- **`HorizontalMCPFieldFindings44Tests` (new, 15 tests):**
  - 113 and 114: short ids, ambiguity, seven digits staying a name.
  - 109: a reused junction's handle.
  - 117: `id` on every op.
  - 116 and 103: a dry run without a revision, compact, committed by
    replay.
  - 108: tracks and vias by component and pad, `connected`.
  - 132, 134 and 135:
    - rule order, merged match keys;
    - via shapes from rules, a definition and a size of their own;
    - re-derivation, `unresolved`, a padstack-less via rule.
  - 115: pin ends, mirrored.
  - 118: a label splitting a wire, the refusals, `net_lines` in check, no
    overlaps.
  - 112: removal taking a corner run, a label and a rail half.
  - 111: refusing by pad name, `copper: "drop"`, pads by name, vias under
    the footprint.
  - 107: the reply's warning, a short in check, a plane over a moved pad.
  - 102:
    - a move carrying a ground symbol and a corner;
    - a stretched wire;
    - `place_junction` moving a junction;
    - a move to another sheet with its cut.
  - 106: a live document holding its `.hprj` alone reads from disk, renders,
    and refuses edits with `RECOVERY_REQUIRED`.
  - 136: a flipped label's orientation saved and read back.
  - 137, 138 and 139: a Power gate folded into a single gate, the label it
    ran to removed, pads kept on the same package, `package_id` read.
- **`HorizontalLiveServerTests`:** `saved` and `wrote`, including a save
  with nothing left to write.
- **`HorizontalDispatchPoolTests`:** the compact cleanup listing.
- **Python `test_mcp`:**
  - optional `expected_revision` and `operation_id`;
  - replaying a compact dry run by its ops;
  - the folder lookup;
  - the uuid on an unnamed wire row.
- **Results:**
  - **Swift:** every suite passes except those this sandboxed runner also
    fails at `140127e`:
    - HorizontalDocumentSavingTests and HorizontalProjectFileWatcherTests;
    - SchematicKeyboardMoveTests and HorizontalKeyboardFocusTests, whose key
      events don't arrive;
    - HorizontalDispatchPoolTests' two mounted live tests, read-only in a
      build without `DEBUG`.

    The window-hosting HorizontalPoolBrowserPaneTests, HorizontalPoolsPaneTests
    and HorizontalWindowChromeTests weren't run, since they hang there.
  - **Python:** 77 tests against a CLI built with swiftc from this tree. Two
    fail, as at `140127e` in the same sandbox: the holder probe's socket bind
    (local binding is off), and test_ato's sync.
  - **Op digests:** the engine's and the schema's agree.
- **Left for the app:**
  - Revert a `.hprj` project and edit straight after (106).
  - Flip a label and save (136).
  - A live commit's `durability` and a `save` after autosave (110).
