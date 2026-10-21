# MCP field findings 46: the TFBGA240 swap

Planning baseline: `f950cce`. Written October 21, 2026. These are items
147–150 in `horizontal-mcp-notes.md`, from the Billo edits on October 21:
U8 swapped to the STM32H757XIH6 (TFBGA240+25), PF7 wired to TIM17, the
FDC6324L pull-ups R73/R74, and the FID channels moved onto the direct ADC
pairs. They were found against the server the session started with, round
45's.

## Findings and changes

147. **`remap_part`'s `pin_map` took only gate/pin uuids.** The part's
     VSSA/VREF- pin had no namesake on the new part (it has VSSA and VREF-),
     and `{"VSSA/VREF-": "VSSA"}` was refused: "pin_map must contain unique,
     existing gateUUID/pinUUID identities". The session looked the uuids up
     instead.
     - **Now:** each side of `pin_map` is named as `connect` names a pin:
       a gateUUID/pinUUID as before, else by name or uuid, the whole name
       first, so VSSA/VREF- is one pin, then as gate/pin, the gate by name,
       suffix or uuid. The old side is looked up on the old part, the new on
       the new.
     - **Shared code:** `pinPath` is split. An entity-level resolver does
       the lookup, and the component one hands it the component's entity.
     - **Messages:** a pin a side can't find says `pin_map:` and lists the
       part's pins. The "no counterpart by name" refusal shows a pin_map by
       name for the first pin it names.
148. **A short id worked for components and nets only.** `remove_net_line`
     with `"id": "92dcf2ab"` said "No wire 92dcf2ab on that sheet", though the
     `apply_ops` description reads as if a short id works anywhere.
     - **Now:** before a batch runs, `HorizontalEditHandles.resolve` makes
       short ids whole:
       - in the fields that name a thing by id (`line`, `junction`,
         `symbol_instance`, `net_tie`, `instance`, `bus`, `member`, `track`,
         `via`, `polygon`, `plane`, `hole`, `keepout`, `dimension`);
       - in the lists `move_symbols` and `move_to_other_sheet` take;
       - in a wire or track end's `junction` and `symbol`;
       - in `id`.
     - **Where it looks:** `HorizontalProjectIDs` holds every uuid key of
       the project's own files, read once a batch and only when a short id
       comes up. It leaves out the pool and `planes.json`. Several matches
       are an `AMBIGUOUS_SELECTOR` with the candidates, named by op.
     - **Batch names:** a batch's own names come first. On an op that makes
       something (`place_text`, `place_junction`, …), a short id that begins
       an id that is there edits that thing. One that begins none is still a
       batch name, so `"id": "c0ffee01"` makes a junction.
     - **Untouched:** components and nets keep their resolvers, which look
       among their own kind and take names too.
     - **Cost:** on a copy of Billo (board.json 1.9 MB, schematic 1.1 MB),
       a dry run naming its wire by 8 digits takes 205 ms against 160 ms by
       the whole id, in a debug build.
149. **A pin couldn't go onto a net with no name.** For R73/R74's new nets
     `connect` refused `"net": ""` ("Missing net"), and `draw_net_line`
     refused a pin on no net ("Connect it first"). The session made a named
     net and renamed it to "".
     - **`connect`:** with `create_net`, a `net` of `""` or none makes a new
       net with no name.
     - **`ensure_net`:** `"name": ""` makes one too. No name finds it, so
       it is always new, and a batch reaches it by its id (`"id": "n1"`). A
       power net still needs a name.
     - **`draw_net_line`:** a pin on no net takes the wire's net, as a block
       port on none already did and as Horizon's wire tool does.
       - Two free ends (pins or ports) get a new net with no name, which
         the reply gives as `created_net`.
       - `connected_pins` names the pins it connected (`R1.A`).
       - A pin marked no-connect is still refused, and so are ends on two
         nets.
     - **Changed test:** `testWiresTakePinNamesAndSayWhyAPinCannotBeWired`
       (round 1) expected a free pin to be refused. It now checks that a
       no-connect pin is refused, and that a free pin joins.
150. **`netlist` was too big to read.** Billo's came back at 320 and 368 KB.
     That is over what a tool reply may carry, so the session read it from
     the saved file with jq.
     - **The cause:** each pin carries its component, gate and pin uuids,
       its gate/pin path and its pads, about 500 bytes where `D2.KB` would
       say the same.
     - **Now:** `netlist` takes `compact`, and the MCP tool sends it
       unless told otherwise.
       - Each pin is REFDES.PIN. Where a part has a pin name more than once,
         as a quad op-amp has IN+, the gate's suffix is added (`U3A.IN+`).
       - A net gives `id`, `name` and `pins`, plus `is_power`, `is_port`, a
         class other than the block's default and `airwire_count` only when
         they apply.
       - `unconnected_pins` are listed the same way.
     - **Size:** on Billo, 22 KB against 348 KB for the full one.
     - **Other callers:** the engine's default and the Python client's
       stay full.

## Not changed

- **Live document changes.** A `LIVE_DOCUMENT_CHANGED`, then a broken pipe,
  came when the document was reopened between calls. Both said to open the
  project again, and that worked.
- **`fields` naming `placed`.** It was refused with the key list
  (`placed_on_board`), which is how round 45's item 143 means it to work.

## Tests

- **Swift:** six in `HorizontalMCPFieldFindings46Tests`, one per item and
  two for 150. `HorizontalMCPFieldFindingsTests` has the changed test above.
  - **The whole suite:** 1,082 run, none fail, 6 skipped.
- **Python:** `test_mcp`, 45 pass. The full run's one failure,
  `test_ato`'s sync, fails at `f950cce` too.
- **Op digest:** `41850defba0fb21a`, unchanged, because no op gained or lost
  a parameter.

## Needs

- **An Xcode rebuild**, so the live app runs the new engine.
- **A new session**, so the MCP server reloads. The schema is unchanged, but
  the `netlist` tool's `compact` and the descriptions are new.

## To check on Billo

- `netlist` without arguments: it should come back inline, at about 22 KB.
- `remove_net_line` with an 8-digit id: run it as a dry run.
- A dry run of `draw_net_line` between two free pins: it should give
  `created_net`.
