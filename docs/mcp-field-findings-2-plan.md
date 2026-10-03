# MCP field findings 2: editing a large live design

Planning baseline: `e4cea91`. Written October 2, 2026, after converting a
real board (an FPGA and AD4080 replaced by an STM32H757 and two AD4003s)
entirely through the live MCP channel: about forty `apply_ops` batches over
nine sheets, a 240-pin MCU, and a 56 MB project whose `planes.json` alone is
42 MB. The edit succeeded, but fifteen gaps cost time or left the design
untidy. Each is listed with what changed.

## Findings and changes

1. **Wires and junctions could not be deleted, and `remove_sheet` refused a
   page with anything on it.** Orphaned wiring from the removed FPGA had to
   be parked on a "delete me" sheet. New ops: `remove_net_line`;
   `remove_junction` (with its wires, labels and power symbols, net-less
   junctions included; `cascade: false` refuses instead); `prune_sheet`
   (dangling wires, net-less junction-only wiring, labels on no net, symbols
   of removed components, unused junctions). `remove_sheet` takes `force`,
   names the components left unplaced, and closes up the page numbers.
   Junction collection after a removal is limited to the removed wires' ends,
   so a junction placed ahead of its wires is not swept up.

2. **`retire_net` left the net's labels, wires and junctions behind**, the
   labels reporting `net_name: null`. Retiring now resolves what each sheet
   draws for the net before removing it, then removes those labels, power
   symbols, wires and junctions, plus block-port connections, bus members and
   their rippers. A net tie on the net is refused. Board copper on it is
   counted; `remove_routing` removes the tracks, vias and planes.

3. **Wire pin endpoints took only pin UUIDs**, and the error for a name was
   "must have a block connection; connect it first". A pin endpoint now takes
   a name or uuid, and can name `component` (and `gate`) instead of a symbol
   instance. Errors say which: no such pin (listing the pins), the symbol does
   not draw it, the pin is on no net, or it is marked no-connect.

4. **Pin names containing "/" were split as gate/pin** —
   `PA13(JTMS/SWDIO)` became gate `PA13(JTMS`. The whole reference is now
   tried as a pin name or uuid first, then split at each slash in turn. A
   `gate` parameter narrows a name to one gate on `connect`, `disconnect`,
   `draw_net_line` (`gate`, `to_gate`), `terminate_pin` and `set_no_connect`.
   A name several pins share is an ambiguity error listing their paths.

5. **Net-less junctions could not be wired to, and `place_net_label`
   silently took over any junction at its point**, even one on another net.
   A junction with no net (floating, or still naming a retired one) now takes
   the net of a wire drawn to it (`adopted_junctions` in the change), and
   `place_junction` and `set_net_line_endpoint` adopt the same way. A label
   or power symbol placed on a junction carrying a different live net is
   refused with the net it would short to.

6. **Live commits timed out and stranded the context.** Batches of 24–60
   ops, particularly ones adding components, ran past the 30 s budget; each
   timeout left the `project_ref` unusable, about a third of the timed-out
   batches had in fact committed, and `transaction_status` answered
   `LIVE_UNAVAILABLE`. Causes and changes:
   - *Cost.* A commit loaded the whole staged project to validate it and
     loaded the pre-edit snapshot again just to count its load diagnostics —
     two full parses of a 42 MB planes file. The diagnostics of the last
     committed snapshot are now cached on the entry, so the next commit, which
     starts from that snapshot, skips that load. Replies carry `timing`
     (`edit_ms`, `load_ms`, `diagnostics_ms`, `commit_ms`) so the rest can
     be measured rather than guessed.
   - *Budget.* Mutations get `HORIZONTAL_MUTATION_TIMEOUT` seconds (default
     180) instead of a read's 30; a request's own deadline is honoured by the
     transport rather than capped at the transport default.
   - *Outcome.* A mutation that fails records a `not_committed` receipt with
     its error, so `transaction_status` says so instead of `unknown`, and the
     same `operation_id` may be resent. When a reply is lost, the client
     reconnects and asks `transaction_status` before returning: the engine
     answers one request at a time, so the question waits for the mutation to
     finish. A committed receipt becomes the result; anything else is raised
     with `outcome: "not_committed"`.
   - *Reconnect.* Reconnecting looked only at the app's discovery file, which
     is inside its sandbox container — hence `LIVE_UNAVAILABLE`. A session
     now remembers the project it was found through and looks beside it, as
     discovery does. A connection lost by an earlier call is reopened before
     the next request is sent, for any method, so the `project_ref` survives.

7. **Replies were 20–40 KB per batch, and one dry run 2.6 MB**, from the
   echoed `normalized_ops`, full change records, the project summary and dry-run
   file previews. Every mutation takes `detail: "compact"`, which keeps each
   change's ids, scalars, short id lists and small count tables, and drops the
   echo (kept on a dry run, which is replayed with it), the previews and the
   summary. The MCP tools default to compact and take `verbose` for the rest.

8. **`place_symbol` could not be given an instance id**, so a batch could not
   place a symbol and wire it. It now takes `id` for a gate drawn for the
   first time.

9. **No "pin → stub → label" helper.** `terminate_pin` draws a wire of
   `length_mm` (default 2.54) straight out of the pin — in the direction it
   points after the symbol's rotation and mirror — ending in a net label or
   power symbol oriented away from it, connecting the pin first if it is on
   no net. `kind` defaults to a power symbol on a power net, a label
   otherwise.

10. **Sheets.** `add_sheet` gave a new page no frame, so it had no title
    block; refused an index already taken; `set_sheet_index` swapped rather
    than inserting; and page numbers shifted under a batch. A new page now
    takes the frame of the last page (or `frame`: a pool frame uuid or
    `"none"`); an index already taken inserts and moves the later pages down;
    `set_sheet_index` moves a page and shifts those between, with `swap` for
    the old behaviour. Page numbers are still evaluated as each op runs — the
    docs and the `apply_ops` description say to use names or uuids in a batch
    that reorders pages.

11. **Power-symbol and pad-number text collided with wiring.** Power symbols
    defaulted to pointing up whatever their style; they now default the way
    the app places them (ground and earth down, dot and antenna up).
    `place_symbol` takes `pin_display_mode` and `display_all_pads`, and
    `set_symbol_display` changes them on drawn symbols — `display_all_pads:
    false` hides a multi-pad pin's pad list.

12. **No way to mark unused pins no-connect.** `set_no_connect` writes a
    connection naming no net — what the app's own tool writes, and what the
    loader already reports as `connection_state: "no_connect"` — or clears
    it. A pin on a net is refused unless `disconnect` is passed.

13. **`remap_part` needed a complete UUID `pin_map`**, impractical for a
    240-pin part. Pins the map leaves out are matched by gate (name, suffix,
    or the only gate) and pin name, pins sharing a name (VSS, VDD) pairing in
    uuid order. Every connected pin must map one way or the other; the error
    names those that do not. The change reports `explicitly_mapped`,
    `mapped_by_name` and `paired_shared_names`.

14. **`search_pool` did not match values**: "2.2 µF" found nothing although
    the part existed. Part values, descriptions and parametric tables are now
    indexed; matching ignores spacing and µ/u; and a quantity (`2.2uF`,
    `2u2`, `2200nF`, `10k`) matches parts whose value, description words or
    parametric data state the same amount.

15. **Reads were too coarse.** `list_net_lines` gives each end's position
    (`from_mm`, `to_mm`) and a pin end's name. `get_component` takes
    `fields`, `pins` (name substring) and `connected`; `list_components` takes
    `fields` and `refdes_prefix`.

## Compatibility

Behaviour that changed for existing callers: `add_sheet` with an occupied
index inserts instead of failing; `set_sheet_index` moves instead of swapping
(pass `swap`); `remove_sheet` renumbers the pages after it; a power symbol's
default orientation follows its style; `retire_net` removes drawing it used
to leave, and its change gains counts beside `removed.connections`;
`remap_part` accepts an incomplete or missing `pin_map`; a label or power
symbol on another net's junction is refused. The engine's default reply is
unchanged — only `detail: "compact"` (the MCP default) is smaller.

## Verification

- `swift test`: 771 tests, 0 failures, the same 6 skips as before. New:
  `HorizontalMCPFieldFindingsTests` (nine tests, one per group of findings)
  and a live-channel test that a commit hands the app its loaded project,
  leaves the next commit's diagnostics cached — the document's archive comes
  back byte for byte, so the cache key matches — and records a failure as
  `not_committed`. Tests whose expectations the behaviour changes were
  updated: sheet insertion and moving, earth's default orientation, and a
  remap refusal that now needs differently named pins to stay a refusal.
- Python: 53 tests pass, among them lost-mutation resolution (committed,
  not committed, unknown), reconnect-before-send, reconnect through the
  holder record, mutation budgets, compact and verbose replies, field
  filters and failure status through MCP. The MCP tests also pass against
  the release CLI. `make native` builds both release products.
- The real 56 MB design, on a disk copy with the release CLI:
  - A 32-op batch adding eight capacitors commits in about 2 s: edit 0.3 s,
    staged load 1.25 s, diagnostics 0 (cached), commit 0.26 s. The compact
    reply is 7 KB, against 13 KB full; the full one grows with batch size.
  - `search_pool "2.2 µF"` finds the capacitor.
  - `connect … "PA13(JTMS/SWDIO)"` resolves.
  - A dry-run `remove_sheet force` on the leftovers sheet reports 134 wires
    and 171 junctions in a 929-byte reply.
  - `prune_sheet` finds only net-less junction-to-junction stubs: 21 on
    Power, 1 on Digital, 15 on ADC.
  - Committing `remove_sheet force`, `prune_sheet` and `terminate_pin` took
    1.5 s and left `check` with no errors.

Not verified here: a live commit in the running app. In the field session it
took over 30 s, against 2 s on disk. Two loads of the project are gone from
the live path: the pre-edit diagnostics and the app's own reload. What is
left is the app redrawing a board whose plane fills take 42 MB, which runs on
the main thread before the next request is answered. The `timing` field and
the 180 s budget make that visible and survivable rather than fatal. If it
stays slow, measure the redraw next.
