# MCP field findings 45: the Billo leftovers

Planning baseline: `b934556`. Written October 18, 2026. These are items
140–146 in `horizontal-mcp-notes.md`, from the Billo edits on October 17:
the bias sync, the THS4541's single symbol and the Pump Voltage PWM label.
They were found against server `b557229`, before round 44.

## Findings and changes

140. **`place_text`'s `origin` read as horizontal.**
     - **The description:** `origin` places a text vertically only. `x_mm` is
       always where it starts, and it runs right.
     - **The reply:**
       - `extent_mm` is the box the text covers, from the same text
         geometry the canvas draws (`renderBoundsPoints`).
       - `overlaps` names what the box runs into on its sheet:
         - symbols, by the box their pin ends span, widened by half a
           grid step;
         - net labels, by their name's run from their junction in the
           direction they face;
         - power symbols, within a grid step of their junction;
         - other texts, by what they draw.
     - **A bug fixed on the way:** points in a line (one point, or pins in
       a column) make a `HorizontalRect` with no area, and `expanded(by:)`
       leaves such a rect empty, so the boxes are widened from their points
       instead.
141. **`terminate_pin` couldn't turn off off-sheet refs.** It takes
     `offsheet_refs` and passes it to the label it ends in.
142. **A label couldn't be edited in place.**
     - **The op:** `place_net_label` given the `id` of a label that is there
       edits that label, found on any sheet.
       - It changes `orientation`, `size_mm` and `offsheet_refs`.
       - `x_mm`, `y_mm` or both move it onto a junction of its net at the new
         point, and the junction it leaves is collected if it now holds
         nothing.
       - Its net stays. Naming another net, or another sheet, is refused.
       - The change says `created: false`, with `moved_to` and
         `junctions_removed`.
     - **Bus labels:** `place_bus_label` does the same.
     - **New labels:** a new label takes its `id`, a UUID or a batch name.
       Both ops define `net_label` and `bus_label` handles, and
       `remove_net_label` resolves them.
143. **`fields` dropped keys silently (MCP).**
     - **Refusing:** `get_component`, `list_components`, `list_parts` and
       `search_pool` refuse a field no record has, naming the keys there
       are. Keys a record carries only sometimes (`board`, `pins`,
       `physical_terminals`, `symbols`, `pin_groups`, `pins_omitted`,
       `note`) still count as known.
     - **`group_pins`:** keeps `pin_groups` and `pins_omitted`, whatever
       `fields` names.
144. **A pool item could only be written whole.** A `pool_write` item may be
     `{"from": uuid, "patch": {...}, "uuid"?, "type"?}`.
     - **Base:** the item `from` names, as `get_pool_item` reads it,
       including an unsaved project-pool change.
     - **Merge:** the patch is merged in as RFC 7396 merges (objects key by
       key, `null` removing a key) and written over the item, or beside it
       under a new `uuid` to derive one.
     - **Refused:** any other key, and a patch that isn't an object.
145. **A commit re-sent what its dry run took.** `apply` and `pool_write`
     commit by `plan_digest` alone, with no `ops` or `items` (or
     `pool_items`).
     - **When it works:** the digest has to name a plan staged at the
       current revision.
     - **Otherwise:** it is a `STALE_REVISION`: "No dry run at this revision
       has that plan_digest".
     - **The full form:** still works, and is still matched by request.
     - **Only these two:** `pour_planes`, `autoroute`,
       `update_project_parts` and `clean_up_project_pool` use the same
       commit path with no ops of their own, and are still matched by
       request. Each method says whether it takes the digest alone, rather
       than the commit path guessing from what is missing.
     - **Receipts:** a digest-alone commit's `plan_digest` is part of the
       hash an `operation_id` is matched against, so two such commits under
       one id are different requests.
     - **MCP:** `ops` and `items` default to empty lists rather than being
       optional, so the advertised schema stays a plain array. Empty is
       refused except for such a commit.
     - **The Python client:** `apply(None, plan_digest=...)` sends no ops.
146. **`render_board` drew a package body over its pads.**
     - **The cause:** the board drawing exporter fills polygons, so a
       package polygon on layer 40 was a solid block over the copper.
     - **The fix:** renders set the top and bottom Package, Assembly and
       Courtyard layers to outline mode. The board drawing export itself is
       unchanged. `render_viewport` goes through the same code.

## Tests

- **Swift, `HorizontalMCPFieldFindings44Tests`, 5 new:**
  - 140: a text's extent starting at x, no overlaps when it is clear, and
    a symbol named when it runs across one.
  - 141 and 142:
    - `offsheet_refs: false` from `terminate_pin`;
    - a label turned and resized under its id;
    - a net change refused;
    - a label moved, with the junction it left collected;
    - a new label named in a batch and edited by the name.
  - 144: a part derived under a new uuid with a changed MPN and a removed
    key, and an unknown key refused.
  - 145: an `apply` commit by digest alone, the stale refusal,
    `pour_planes` still matched by request, and a `pool_write` commit by
    digest alone.
  - 146: a package body rendered alone shows its outline and nothing
    inside. With outline mode off, 881,721 pixels inside it come out dark.
- **Python `test_mcp`:**
  - 143: an unknown field refused in `get_component` and
    `list_components`, and `pin_groups` kept.
  - 145: digest-alone commits through `apply_ops` and `pool_write`, a bare
    commit refused, and the stale refusal.
- **Results:**
  - **Swift:** 993 run under the sandbox. Every failure is in a suite that
    fails at `b934556` too: document saving, the file watcher, the
    key-event suites, and two mounted pool tests that are read-only without
    `DEBUG`. The window-hosting pool browser, pools pane and window chrome
    suites weren't run, since they hang there.
  - **Python:** 78 against a CLI built with swiftc from this tree. Two fail,
    as at `b934556`: the holder probe's socket bind, and test_ato's sync.
  - **Op digest:** `75f6e274a481ca68`, 80 ops; the engine's and the
    schema's agree.
- **Left for the app:** a label edited by id in the live document (142),
  and a render of U7 on Billo (146).
